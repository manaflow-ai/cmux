//! Part of `Hub`; see `hub/mod.rs`. A Codex chat whose stop condition's goal is still open but
//! that sits idle goes on by itself, a bounded number of times; then the Chief that made it
//! hears once, by name.
//!
//! Codex keeps the stop condition as its own goal (`stop_condition.rs`) and is meant to start
//! the goal's next turns itself. Four Codex chats in 24 h did not (acp-chief-issues 2026-11-24
//! to 11-27): their turn ended `ready` on a status line with no result while the goal stayed
//! open, or Codex marked the goal `blocked`, and the Chief that made them found out only on its
//! own timed checks, hours later.
//!
//! - At the end of each completed turn of a Codex chat with a stop condition, a goal that is open
//!   (`stop_condition::goal_open`) arms one wait ([`NUDGE_WAITS_MS`], the next of three: 3, 10
//!   and 30 minutes). When it ends and the chat is still idle (no turn, nothing queued, no Stop of
//!   the person's holding it, no task of its own running whose end brings it its next turn, its
//!   goal still open), acpmux prompts it once to go on, with prompt id `goal-nudge-<turn>-<n>`.
//!   Any turn's end, whatever its status, ends the wait; a completed one arms the next. A sign of
//!   its model with no turn (Codex going on by itself) waits again.
//! - After the third nudge's turn ends with the goal still open, the chat's owner gets one notice
//!   naming it: the Chief whose turn made the chat ([`CHIEF_OWNER_TAG`], stamped at creation,
//!   because a Chief's turn session is gone long before its chat ends), as a prompt to that
//!   Chief's stable session (tag `cmux.chief.inbox`); with no Chief, the lane's parent if it is
//!   open. Only a turn whose prompt is not acpmux's own (a person's or another agent's prompt; not
//!   a nudge, an inbox notice or a digest) starts the count again, so the nudges stay bounded.
//! - A goal Codex reports `blocked` (lifecycle `stalled`) tells the owner once, until it is
//!   unblocked: a prompt that leaves it blocked tells nobody again.
//! - A failed turn whose continuations ran out (`auto_resume.rs`) with the goal open tells the
//!   Chief the same way, once; a lane's parent already hears it from `lane_stranded`.
//! - The state is in memory: a restart arms nothing until the chat's next turn ends.

use super::*;

/// On a chat a Chief's turn made: that Chief's participant id (`agent_mux`, `agent_…`), copied at
/// creation from the creator's `cmux.chief.participant` (or its own owner), so the chat still
/// knows its Chief after the turn session that made it is gone.
pub(super) const CHIEF_OWNER_TAG: &str = "cmux.chief.owner";
/// On a Chief's stable session (optchat-chief `chief_inbox.rs`): its participant id.
const CHIEF_INBOX_TAG: &str = "cmux.chief.inbox";
/// The waits before each nudge of an open goal left idle.
pub(super) const NUDGE_WAITS_MS: [u64; 3] = [3 * 60_000, 10 * 60_000, 30 * 60_000];
/// The prompt id prefix of a nudge.
pub(super) const NUDGE_PREFIX: &str = "goal-nudge-";
/// Who the nudges and the notice come from.
const SENDER: &str = "acpmux";

/// A chat's open goal left idle: how far its nudges went.
#[derive(Debug, Default)]
pub(crate) struct GoalWatch {
    /// Bumped at every arm and every turn end: a wait that finds it moved does nothing.
    generation: u64,
    /// Nudges sent since the last turn whose prompt was not acpmux's own.
    nudges: usize,
    /// The owner heard about this count.
    told: bool,
    /// The owner heard that the goal is blocked: not again until it is unblocked.
    told_blocked: bool,
}

/// What a turn's end does to the watch.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Step {
    /// Nothing: no stop condition, no Codex, or the goal is done.
    Nothing,
    /// Wait this long, then nudge.
    Wait(u64),
    /// Tell the owner, once: the nudges ran out, or the goal is blocked.
    Tell(&'static str),
}

/// The step at the end of a turn of a chat with `meta`, given its `watch`; `watch` moves with
/// it. `own`: the turn's prompt was acpmux's own (a nudge, an inbox notice, a digest), which
/// starts no new count. `completed`: it ended well; a failed turn is `auto_resume.rs`'s, a
/// stopped one the person's, and neither arms anything.
pub(super) fn step(meta: &SessionMeta, own: bool, completed: bool, watch: &mut GoalWatch) -> Step {
    watch.generation = watch.generation.wrapping_add(1);
    if !own {
        watch.nudges = 0;
        watch.told = false;
    }
    if !completed || !super::stop_condition::is_codex(meta) || meta.stop_condition.is_none() {
        return Step::Nothing;
    }
    let blocked = meta.goal.as_ref().is_some_and(|g| g.lifecycle() == "stalled");
    if !blocked {
        watch.told_blocked = false;
    } else if std::mem::replace(&mut watch.told_blocked, true) {
        return Step::Nothing;
    } else {
        return Step::Tell("its goal is blocked");
    }
    if !super::stop_condition::goal_open(meta) {
        return Step::Nothing;
    }
    match NUDGE_WAITS_MS.get(watch.nudges) {
        Some(wait) => Step::Wait(*wait),
        None => tell_once(watch, "it stopped with its goal open after 3 nudges"),
    }
}

fn tell_once(watch: &mut GoalWatch, why: &'static str) -> Step {
    if std::mem::replace(&mut watch.told, true) { Step::Nothing } else { Step::Tell(why) }
}

/// The Chief that owns chat `m`: its own Chief's turn tag, else the owner stamped on it.
pub(super) fn chief_of(m: &SessionMeta) -> Option<String> {
    let live = |key: &str| {
        let tag = m.tags.get(key)?;
        let expired = tag.expires_at.is_some_and(|e| e <= crate::store::now_ms());
        (!expired && !tag.value.is_empty()).then(|| tag.value.clone())
    };
    live(crate::prompt_provenance::CHIEF_PARTICIPANT_TAG).or_else(|| live(CHIEF_OWNER_TAG))
}

/// The resume cause of a turn of `session` cut with `error` (`turn_errors::resume_cause`); a turn
/// of a chat whose goal is open that acpmux ended as stalled (`stalled_turn.rs`) goes on as a cut
/// connection does, `transport`, with its attempts: its model went quiet mid-turn, and its owner
/// waits for the result (acp-chief-issues 2026-11-27 08:25). Any other stalled turn waits for its
/// next prompt, as before.
pub(super) fn cut_cause(session: &Session, error: &str) -> Option<&'static str> {
    super::turn_errors::resume_cause(error, error).or_else(|| {
        (Hub::is_stalled_error(error) && session.read_meta(super::stop_condition::goal_open))
            .then_some("transport")
    })
}

/// The nudge's words for a goal `objective`.
fn nudge_text(objective: &str) -> String {
    format!(
        "Your goal is still open and this chat stopped: {objective}\nCheck what already \
         finished, then go on until the goal is met. If something blocks it, say exactly what, \
         and report that."
    )
}

impl Hub {
    /// Stamps on a new chat's `meta` the Chief whose turn made it ([`CHIEF_OWNER_TAG`]): that
    /// turn's session is gone long before the chat ends, and an open goal left idle tells it.
    pub(super) fn stamp_chief_owner(&self, meta: &mut SessionMeta) {
        let creator = meta.created_by.as_ref().and_then(|c| c.session.as_deref());
        let creator = creator.and_then(|id| self.session_meta_by_id(id));
        if let Some(chief) = creator.as_ref().and_then(chief_of) {
            let tag = crate::store::Tag { value: chief, expires_at: None };
            meta.tags.insert(CHIEF_OWNER_TAG.to_owned(), tag);
        }
    }

    /// At the end of a turn of `session`, prompt `prompt_id`, `completed` or not (module docs).
    pub(super) fn goal_turn_ended(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        completed: bool,
    ) {
        let meta = session.meta();
        // The turn being ended (`finish_turn`): an inbox notice's or a digest's is acpmux's own.
        let notice = session
            .ending
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .is_some_and(|t| t.notice && t.prompt_id == prompt_id);
        let own = notice || prompt_id.starts_with(NUDGE_PREFIX);
        let (step, generation) = {
            let mut watch = session.goal_watch.lock().unwrap_or_else(|e| e.into_inner());
            let step = step(&meta, own, completed, &mut watch);
            (step, watch.generation)
        };
        match step {
            Step::Nothing => {}
            Step::Tell(why) => self.tell_goal_owner(session, why, true),
            Step::Wait(ms) => self.arm_goal_nudge(session, generation, ms),
        }
    }

    /// Waits `ms`, then nudges `session` when it is still idle on an open goal and nothing moved
    /// its watch (`generation`) since.
    fn arm_goal_nudge(self: &Arc<Self>, session: &Arc<Session>, generation: u64, ms: u64) {
        let heard = session.heard.load(Ordering::SeqCst);
        let (hub, session) = (self.clone(), session.clone());
        self.scope.spawn_until_cancelled("goal-nudge", async move {
            tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
            hub.goal_nudge(&session, generation, heard).await;
        });
    }

    async fn goal_nudge(self: &Arc<Self>, session: &Arc<Session>, generation: u64, heard: u64) {
        let meta = session.meta();
        let idle = session.turn().is_none()
            && session.queue.lock().unwrap_or_else(|e| e.into_inner()).is_empty()
            && session.status() != SessionStatus::Closed
            && !session.purged.load(Ordering::SeqCst);
        // The person stopped it, or a task of its own runs whose end gives it its next turn
        // (`bg_notify.rs`), whose end arms the next wait: nothing to do.
        let held =
            session.stop_hold.load(Ordering::SeqCst) != 0 || self.bg_notifying_count(session) > 0;
        if !idle || held || !super::stop_condition::goal_open(&meta) {
            return;
        }
        let nudge = {
            let mut watch = session.goal_watch.lock().unwrap_or_else(|e| e.into_inner());
            if watch.generation != generation {
                return;
            }
            // Its model did something since the wait began (Codex went on by itself): wait again.
            if session.heard.load(Ordering::SeqCst) != heard {
                None
            } else {
                watch.nudges = watch.nudges.saturating_add(1);
                Some(watch.nudges)
            }
        };
        let Some(n) = nudge else {
            let wait = NUDGE_WAITS_MS.first().copied().unwrap_or_default();
            self.arm_goal_nudge(session, generation, wait);
            return;
        };
        let objective = meta.stop_condition.clone().unwrap_or_default();
        let notice =
            json!({"sender": SENDER, "severity": "info", "title": "Your goal is still open"});
        let text = crate::prompt_provenance::notice_text(&notice, &nudge_text(&objective));
        let opts = PromptOptions {
            prompt_id: Some(format!("{NUDGE_PREFIX}{}-{n}", meta.turn_count)),
            provenance: Some(crate::prompt_provenance::notice(&notice, &session.id)),
            agent: Some(SENDER.to_owned()),
            class: Some(crate::prompt_class::PromptClass::Fyi),
            ..PromptOptions::default()
        };
        tracing::info!(session = %session.id, nudge = n, "an open goal left idle: nudged");
        let blocks = vec![json!({"type": "text", "text": text})];
        // Never steered: it waits behind anything queued meanwhile.
        if let Err(e) = self.prompt_with(session, blocks, SENDER, false, opts).await {
            tracing::warn!(session = %session.id, "an open goal's nudge: {}", e.message);
        }
    }

    /// A turn of `session` failed and its continuations ran out (`auto_resume.rs`): with its goal
    /// open, its Chief hears once (a lane's parent hears from `lane_stranded`).
    pub(super) fn goal_retries_exhausted(self: &Arc<Self>, session: &Arc<Session>) {
        if !session.read_meta(super::stop_condition::goal_open) {
            return;
        }
        let first = {
            let mut watch = session.goal_watch.lock().unwrap_or_else(|e| e.into_inner());
            !std::mem::replace(&mut watch.told, true)
        };
        if first {
            self.tell_goal_owner(session, "its turn failed and acpmux's retries ran out", false);
        }
    }

    /// Where `session`'s owner hears about it: its Chief's stable session, else, with
    /// `parent_too`, its lane's open parent.
    pub(super) fn goal_owner(&self, session: &Session, parent_too: bool) -> Option<Arc<Session>> {
        let chief = session.read_meta(chief_of);
        if let Some(chief) = chief {
            let inbox = self.live_session_handles().into_iter().find(|s| {
                s.status() != SessionStatus::Closed
                    && s.read_meta(|m| {
                        m.tags.get(CHIEF_INBOX_TAG).is_some_and(|t| t.value == chief)
                    })
            });
            if inbox.is_some() {
                return inbox;
            }
        }
        if !parent_too {
            return None;
        }
        let parent =
            session.read_meta(|m| m.tags.get(super::lane_reports::TAG).map(|t| t.value.clone()))?;
        self.exit_route(&session.id, &parent).ok().map(|r| r.to)
    }

    /// Tells `session`'s owner once that it stopped short of its goal (`why`); its lane's parent
    /// only with `parent_too` (`goal_owner`).
    pub(super) fn tell_goal_owner(
        self: &Arc<Self>,
        session: &Arc<Session>,
        why: &'static str,
        parent_too: bool,
    ) {
        let Some(to) = self.goal_owner(session, parent_too) else {
            tracing::info!(session = %session.id, why, "an open goal's owner is not here: not told");
            return;
        };
        let meta = session.meta();
        let name = if meta.name.is_empty() { meta.id.clone() } else { meta.name.clone() };
        let notice = json!({"sender": SENDER, "severity": "warning",
            "title": format!("Chat {name} stopped short of its goal")});
        let body = format!(
            "Chat {name} (`{}`): {why}. Its last turn ended with no result. Read it with `acpmux \
             history {}`, then resume it with a concrete next step or hand its task to another agent.",
            meta.id, meta.id
        );
        let text = crate::prompt_provenance::notice_text(&notice, &body);
        let opts = PromptOptions {
            prompt_id: Some(format!("goal-told-{}-{}", meta.id, meta.turn_count)),
            resend: true,
            provenance: Some(crate::prompt_provenance::notice(&notice, &to.id)),
            agent: Some(SENDER.to_owned()),
            class: Some(crate::prompt_class::PromptClass::Block),
            ..PromptOptions::default()
        };
        tracing::warn!(session = %session.id, to = %to.id, why, "an open goal stopped: owner told");
        let hub = self.clone();
        self.scope.spawn_until_cancelled("goal-told", async move {
            let blocks = vec![json!({"type": "text", "text": text})];
            if let Err(e) = hub.prompt_with(&to, blocks, SENDER, true, opts).await
                && e.data.as_ref().is_none_or(|d| d["held"] != true)
            {
                tracing::warn!(to = %to.id, "an open goal's notice to its owner: {}", e.message);
            }
        });
    }
}

#[cfg(test)]
#[path = "goal_watch_tests.rs"]
mod tests;
