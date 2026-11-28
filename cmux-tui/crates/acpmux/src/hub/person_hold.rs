//! Part of `Hub`; see `queue.rs`. The person's prompts to a chat the config names wait a while to
//! go in together, unless a small model says one is urgent.
//!
//! Leo, 2026-11-20: "to be honest sometimes if im raging i think you can batch my sh*t too it's
//! not always something i need that's on fire, at the very least another model could go case by
//! case if something actually warrants rushing vs just waiting lke 30s or so which isnt a big deal
//! to wait".
//!
//! - Which chats: those whose name `personHold.sessions` lists (`config.rs`); no other chat's
//!   prompt waits. Nothing is listed by default.
//! - The hold: the person's prompt that would start a turn in an idle chat waits
//!   [`DEFAULT_HOLD_MS`] (`personHold.ms`) from its arrival, in the queue (its `queued` record is
//!   written first, so a crash loses nothing and a restart runs it at once). The person's prompts
//!   that come meanwhile queue behind it, in order, and join its turn (`digest.rs`
//!   `take_joined`): one turn, each prompt's words as sent, oldest first.
//! - The triage: each prompt that holds or joins a hold is read once by the harness's small model
//!   ([`triage_prompt`], `complete.rs` `complete_own`), bounded by [`TRIAGE_TIMEOUT`]. "rush"
//!   ends the hold at once: the held prompts start their turn now, still together. So does an
//!   error, a timeout or an answer that is neither word: a triage that fails is today's delivery.
//! - What never waits: the same prompts an agent message's gather window lets go
//!   (`agent_gather.rs` `gathers`: a slash command, uploads, a trigger, a no-queue send, a
//!   prompt let in again), and any prompt to a chat that is busy or has prompts waiting: it
//!   queues as before. Nothing is reordered: a prompt only ever waits behind the ones before it,
//!   and the person's prompts keep going ahead of waiting agent messages (`digest.rs`).

use super::*;
use std::time::Duration;

/// How long the person's prompt to a held chat waits for the ones after it, when the config
/// names no other (Leo: "waiting lke 30s or so").
pub(in crate::hub) const DEFAULT_HOLD_MS: u64 = 30_000;
/// The longest the small model's triage of one prompt runs; past it the hold ends.
pub(in crate::hub) const TRIAGE_TIMEOUT: Duration = Duration::from_secs(15);
/// The triage's answer, in tokens: one word.
const TRIAGE_MAX_TOKENS: u32 = 8;
/// The most of a prompt's words the triage reads.
const TRIAGE_TEXT_BYTES: usize = 3000;

/// What answers the triage in place of the small model (tests): `Ok(true)` rush, `Ok(false)`
/// wait, `Err` a failed triage.
pub type PromptTriager = Arc<dyn Fn(String) -> Result<bool, String> + Send + Sync>;

/// The held prompt of a chat (`Session::person_hold`), by its turn id.
#[derive(Debug, Clone)]
pub(in crate::hub) struct Hold {
    turn_id: String,
    until: tokio::time::Instant,
    /// Until the window ends or the triage ends it. Once closed, the entry stays until the
    /// prompt's turn starts, so that turn takes the person's prompts behind it (`folds`).
    open: bool,
}

/// How long the person's prompts to chat `name` wait (module docs), when the config holds them.
pub(in crate::hub) fn hold_ms(cfg: &crate::config::Config, name: &str) -> Option<u64> {
    let hold = cfg.person_hold.as_ref()?;
    let name = name.trim();
    if name.is_empty() || !hold.sessions.iter().any(|s| s.trim() == name) {
        return None;
    }
    Some(hold.ms.unwrap_or(DEFAULT_HOLD_MS)).filter(|&ms| ms > 0)
}

/// Whether the person's prompt `p` may wait (module docs): what an agent message's gather window
/// would let go never does.
pub(in crate::hub) fn holds(p: &super::queue::Slot<'_>) -> bool {
    p.agent.is_none()
        && !p.no_queue
        && !p.admitted
        && p.after_turn.is_none()
        && !p.interrupt
        && !p.steer_on_start
        && !crate::prompt_provenance::is_trigger(p.provenance)
        && super::forum::slash_command(p.blocks).is_none()
        && !crate::prompt_uploads::any(p.blocks)
        && !super::subsession_guard::is_family_prompt(p.provenance)
        && !super::digest::inbox_digest::is_digest(p.provenance)
        && !super::goal_tools::is_continuation(p.provenance)
}

/// Opens the hold of `turn_id` for `ms`. Called under the chat's `admit` lock.
pub(in crate::hub) fn open(session: &Session, turn_id: &str, ms: u64) {
    let until = tokio::time::Instant::now() + Duration::from_millis(ms);
    *session.person_hold.lock().unwrap_or_else(|e| e.into_inner()) =
        Some(Hold { turn_id: turn_id.to_owned(), until, open: true });
}

/// Whether a hold is open in `session`: the person's prompt that queues now joins it.
pub(in crate::hub) fn is_open(session: &Session) -> bool {
    let hold = session.person_hold.lock().unwrap_or_else(|e| e.into_inner());
    hold.as_ref().is_some_and(|h| h.open && tokio::time::Instant::now() < h.until)
}

/// When the hold of `turn_id` ends, while it is open; else closes it.
pub(in crate::hub) fn until(session: &Session, turn_id: &str) -> Option<tokio::time::Instant> {
    let mut hold = session.person_hold.lock().unwrap_or_else(|e| e.into_inner());
    let h = hold.as_mut().filter(|h| h.turn_id == turn_id && h.open)?;
    if tokio::time::Instant::now() < h.until {
        return Some(h.until);
    }
    h.open = false;
    None
}

/// Ends the hold now (the triage said rush, or failed): the held prompt's wait wakes and starts
/// its turn, with the person's prompts behind it.
pub(in crate::hub) fn release(session: &Session) {
    let released = {
        let mut hold = session.person_hold.lock().unwrap_or_else(|e| e.into_inner());
        hold.as_mut().filter(|h| h.open).map(|h| h.open = false).is_some()
    };
    if released {
        session.queue_moved.notify_waiters();
    }
}

/// Forgets the hold of `turn_id` (it was withdrawn or refused).
pub(in crate::hub) fn end(session: &Session, turn_id: &str) {
    let mut hold = session.person_hold.lock().unwrap_or_else(|e| e.into_inner());
    if hold.as_ref().is_some_and(|h| h.turn_id == turn_id) {
        *hold = None;
    }
}

/// Whether the turn `turn_id` starting now is a held prompt's: it takes the person's prompts
/// queued behind it (`digest.rs` `take_joined`). Forgets the hold.
pub(in crate::hub) fn folds(session: &Session, turn_id: &str) -> bool {
    let mut hold = session.person_hold.lock().unwrap_or_else(|e| e.into_inner());
    if hold.as_ref().is_some_and(|h| h.turn_id == turn_id) {
        *hold = None;
        return true;
    }
    false
}

/// The blocks of one turn of the person's prompts a hold gathered, `parts` oldest first: each
/// prompt's blocks as sent, a blank line between two.
pub(in crate::hub) fn person_blocks(parts: &[super::digest::Part]) -> Vec<Value> {
    let mut blocks = Vec::new();
    for (i, part) in parts.iter().enumerate() {
        if i > 0 {
            blocks.push(serde_json::json!({"type": "text", "text": "\n\n"}));
        }
        blocks.extend(part.run.blocks.iter().cloned());
    }
    blocks
}

/// What the small model reads for one prompt: its words, cut to [`TRIAGE_TEXT_BYTES`].
pub(in crate::hub) fn triage_prompt(text: &str) -> String {
    let text = crate::complete::cut(text.trim(), TRIAGE_TEXT_BYTES);
    format!(
        "A person sent this message to a coding agent that coordinates other agents. It can wait \
         about 30 seconds so that messages sent right after it go in together, unless it is \
         urgent. Urgent: something is on fire or broken now (an outage, a broken build or \
         release, data loss), it says now, urgent, asap or stop, or it is a direct question \
         that needs an answer before anything else. Not urgent: an idea, a request for later \
         work, a remark, venting, more detail on an earlier message.\n\nAnswer with one word, \
         RUSH or WAIT.\n\nMessage:\n<<<\n{text}\n>>>"
    )
}

/// The small model's answer: `Some(true)` rush, `Some(false)` wait, `None` neither word.
pub(in crate::hub) fn parse_triage(answer: &str) -> Option<bool> {
    let upper = answer.to_ascii_uppercase();
    match (upper.contains("RUSH"), upper.contains("WAIT")) {
        (true, false) => Some(true),
        (false, true) => Some(false),
        _ => None,
    }
}

impl Hub {
    /// Has the small model read the person's prompt `text` to held chat `session` (module docs),
    /// off the prompt's path: rush, an error, a timeout or an unclear answer ends the hold.
    pub(in crate::hub) fn triage_held(self: &Arc<Self>, session: &Arc<Session>, text: String) {
        let hub = Arc::clone(self);
        let session = Arc::clone(session);
        self.scope.spawn_named("person-hold-triage", async move {
            let started = std::time::Instant::now();
            let verdict = hub.triage(text).await;
            let ms = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
            match &verdict {
                Ok(false) => tracing::info!(session = %session.id, ms, "person hold: wait"),
                Ok(true) => tracing::info!(session = %session.id, ms, "person hold: rush"),
                Err(e) => {
                    tracing::info!(session = %session.id, ms, reason = %e, "person hold: triage failed, delivering")
                }
            }
            if !matches!(verdict, Ok(false)) {
                release(&session);
            }
        });
    }

    async fn triage(self: &Arc<Self>, text: String) -> Result<bool, String> {
        let triager = self.prompt_triager.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let answer = match triager {
            Some(triager) => {
                let run = tokio::task::spawn_blocking(move || triager(text));
                match tokio::time::timeout(TRIAGE_TIMEOUT, run).await {
                    Ok(Ok(verdict)) => return verdict,
                    Ok(Err(e)) => return Err(e.to_string()),
                    Err(_) => return Err("timed out".into()),
                }
            }
            None => {
                let call = self.complete_own(
                    Some("claude"),
                    triage_prompt(&text),
                    TRIAGE_MAX_TOKENS,
                    TRIAGE_TIMEOUT,
                    super::complete::ModelFallback::HarnessDefault,
                );
                match tokio::time::timeout(TRIAGE_TIMEOUT + Duration::from_secs(1), call).await {
                    Ok(Ok(answer)) => answer,
                    Ok(Err(e)) => return Err(e.reason().to_owned()),
                    Err(_) => return Err("timed out".into()),
                }
            }
        };
        parse_triage(&answer).ok_or_else(|| "neither rush nor wait".into())
    }

    /// Who answers the triage in place of the small model (tests); `None` the small model.
    pub fn set_prompt_triager(&self, triager: Option<PromptTriager>) {
        *self.prompt_triager.lock().unwrap_or_else(|e| e.into_inner()) = triager;
    }
}

#[cfg(test)]
#[path = "person_hold_tests.rs"]
mod tests;
