//! A bridged desktop chat (`bridge.rs`) whose app's turn failed on the account's rate limit
//! holds what is sent to it until the limit resets, then gives the app one message (Leo,
//! 2026-11-19: "I hope we aren't getting the fucking 429s anymore in our fucking app ... the GUI
//! ones kept like getting busted").
//!
//! A chat acpmux runs itself holds its turns at a 429 and continues the cut one (`auto_resume.rs`).
//! A Claude desktop chat runs in its own app: acpmux only puts each message into the app's inbox,
//! and the app starts a turn for it at once. Under a rate limit each of those turns failed again
//! with "API Error: Request rejected (429)", sending the whole context again each time, and the
//! watch (`watch.rs`) showed that error as the agent's answer, so every message read as answered
//! while the app had answered none of them, and nothing went on after the reset until the next
//! message happened to arrive.
//!
//! - The watch ends a turn whose app wrote an API error line (`isApiErrorMessage`) as failed, with
//!   that error, never as an answer ([`api_error`]).
//! - A failed turn of a bridged chat on the account's usage or rate limit holds the chat
//!   ([`Hub::bridge_rate_limited`]) until the reset the error names
//!   (`auto_resume/reset_hint.rs`), else for [`MIN_HOLD_MS`], doubling on each failure in a row up
//!   to [`MAX_HOLD_MS`]. A turn that completes ends the doubling.
//! - While held, a message to the chat is accepted (`state: "held"`) and kept here, never put
//!   into the app's inbox. A resend of its prompt id finds it, as a delivered one's does.
//! - At the reset the app gets one message: a line saying its last turn hit the rate limit, then
//!   every held message in the order it came. Each held prompt's call answers with that one turn.
//!   With nothing held the line goes alone, so the message the limit cut is still answered.
//! - Each hold and its end are logged (`rate_limit_held`, `rate_limit_lifted`, with `bridged`).

use super::{Deliveries, Hub, Outcome, Session, delivered_ids, deliveries};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;
use tokio::sync::watch;

/// The shortest hold when the error names no reset: a per-minute rate limit's window.
pub(super) const MIN_HOLD_MS: u64 = 60_000;
/// The longest hold one failure in a row grows to.
pub(super) const MAX_HOLD_MS: u64 = 60 * 60_000;

#[cfg(test)]
pub(super) static TEST_MIN_HOLD_MS: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);

fn min_hold_ms() -> u64 {
    #[cfg(test)]
    {
        let ms = TEST_MIN_HOLD_MS.load(std::sync::atomic::Ordering::SeqCst);
        if ms > 0 {
            return ms;
        }
    }
    MIN_HOLD_MS
}

/// The line the app reads ahead of what the hold kept.
pub(super) const CONTINUE_LINE: &str = "acpmux: your last turn stopped on the account's rate limit (HTTP 429), so nothing you were sent since reached you until the limit reset. Check what that turn finished, answer the message it was working on, then each message below.";

/// A message the hold keeps, in the order it came.
struct Parked {
    prompt_id: String,
    wire: String,
    sender: String,
}

#[derive(Default)]
struct Hold {
    /// Absolute ms; `None` when the chat is not held.
    until: Option<u64>,
    /// The last hold's length, doubled by the next failure in a row.
    last_ms: u64,
    held: Vec<Parked>,
    /// The hold's timer task runs.
    timer: bool,
    /// Wakes the timer to read `until` again before its sleep ends (a test's reset, [`lift`]).
    wake: Arc<tokio::sync::Notify>,
}

static HOLDS: LazyLock<Mutex<HashMap<String, Hold>>> = LazyLock::new(Default::default);

fn holds() -> std::sync::MutexGuard<'static, HashMap<String, Hold>> {
    HOLDS.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn now_ms() -> u64 {
    crate::store::now_ms()
}

/// The error of a Claude Code API error line (`isApiErrorMessage`: the app's own record of a
/// request the provider refused, e.g. `"error": "rate_limit"`, `"apiErrorStatus": 429`), which
/// ends its turn as failed. `None` for any other line.
pub(in crate::hub) fn api_error(family: &str, record: &Value) -> Option<String> {
    if family != "claude"
        || record.get("type").and_then(Value::as_str) != Some("assistant")
        || record.get("isApiErrorMessage").and_then(Value::as_bool) != Some(true)
        || record.get("isSidechain").and_then(Value::as_bool) == Some(true)
    {
        return None;
    }
    let text = record
        .pointer("/message/content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    let status = record.get("apiErrorStatus").and_then(Value::as_u64);
    let text = match (text.trim().is_empty(), status) {
        (false, _) => text,
        (true, Some(status)) => format!("API Error: {status}"),
        (true, None) => "API Error".to_owned(),
    };
    Some(text)
}

/// Whether an API error line is the account's usage or rate limit.
pub(in crate::hub) fn rate_limited(record: &Value, error: &str) -> bool {
    record.get("apiErrorStatus").and_then(Value::as_u64) == Some(429)
        || record.get("error").and_then(Value::as_str) == Some("rate_limit")
        || crate::turn_errors::is_usage_limit_error(error)
}

/// When `session_id` is held, until when.
pub(in crate::hub) fn held_until(session_id: &str) -> Option<u64> {
    holds().get(session_id).and_then(|h| h.until)
}

/// The reset comes now for `session_id`'s hold: a test lifts it when it has seen what it waits
/// for, so no step of it races a real clock on a loaded runner.
#[cfg(test)]
pub(super) fn lift(session_id: &str) {
    let mut all = holds();
    let Some(hold) = all.get_mut(session_id) else { return };
    if hold.until.is_some() {
        hold.until = Some(now_ms());
    }
    hold.wake.notify_one();
}

/// A turn of `session_id` completed: the next failure holds for the shortest wait again.
pub(in crate::hub) fn settled(session_id: &str) {
    let mut all = holds();
    if all.get(session_id).is_some_and(|h| h.until.is_none() && !h.timer) {
        all.remove(session_id);
    }
}

/// Keeps `prompt_id` while `session_id` is held: its delivery is claimed under a key no transcript
/// line carries, so a resend finds it, and it goes with the hold's one message. `None` when the
/// chat is not held (it is delivered now), else the delivery's outcome to wait on and the reset.
pub(super) fn park(
    session_id: &str,
    prompt_id: &str,
    text: &str,
    wire: &str,
    sender: &str,
) -> Option<Result<(watch::Receiver<Outcome>, u64), watch::Receiver<Outcome>>> {
    let mut all = holds();
    let hold = all.get_mut(session_id)?;
    let until = hold.until?;
    let key = format!("held-{}", uuid::Uuid::now_v7());
    let claimed = deliveries().claim(key.clone(), session_id, prompt_id, text, wire, false);
    let rx = match claimed {
        Ok(rx) => rx,
        Err(rx) => return Some(Err(rx)),
    };
    // Never the line a Codex rollout shows by its text (`delivered_text`): it has not gone yet.
    if let Some(p) = deliveries().by_uuid.get_mut(&key) {
        p.shown = true;
    }
    hold.held.push(Parked {
        prompt_id: prompt_id.to_owned(),
        wire: wire.to_owned(),
        sender: sender.to_owned(),
    });
    Some(Ok((rx, until)))
}

#[cfg(test)]
pub(super) static TEST_HELD_ANSWER_WAIT_MS: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);

fn held_answer_wait() -> Duration {
    #[cfg(test)]
    {
        let ms = TEST_HELD_ANSWER_WAIT_MS.load(std::sync::atomic::Ordering::SeqCst);
        if ms > 0 {
            return Duration::from_millis(ms);
        }
    }
    super::ANSWER_WAIT
}

/// A held prompt's answer: its turn once the reset sent it and the app ended that turn. A hold
/// that outlasts the call's wait (`ANSWER_WAIT`) answers `answered: false` as any long turn
/// does, and also `held: true` with `rateLimitedUntil`: the message still waits here and goes at
/// the reset, so the sender reads that, not a quiet end.
pub(super) async fn held_answer(
    session_id: &str,
    prompt_id: &str,
    mut rx: watch::Receiver<Outcome>,
    until: u64,
) -> Result<Value, crate::rpc::RpcError> {
    let wait = rx.wait_for(Option::is_some);
    let outcome = tokio::time::timeout(held_answer_wait(), wait)
        .await
        .ok()
        .and_then(Result::ok)
        .and_then(|o| o.clone());
    let unanswered = outcome.is_none();
    let mut reply = super::answer(prompt_id, outcome, None);
    if unanswered
        && let Some(meta) = reply
            .as_mut()
            .ok()
            .and_then(|v| v.pointer_mut("/_meta/acpmux"))
            .and_then(Value::as_object_mut)
    {
        meta.insert("held".to_owned(), json!(true));
        meta.insert("rateLimitedUntil".to_owned(), json!(held_until(session_id).unwrap_or(until)));
    }
    reply
}

impl Deliveries {
    /// The kept delivery of each of `riders` answers as `prompt_id`'s does.
    fn ride(&mut self, session_id: &str, prompt_id: &str, riders: Vec<String>) {
        if let Some(p) = self
            .by_uuid
            .values_mut()
            .find(|p| p.session_id == session_id && p.prompt_id == prompt_id)
        {
            p.riders = riders;
        }
    }
}

impl Hub {
    /// The app's turn in bridged chat `session` failed on the account's limit (`error`): the chat
    /// is held until the reset. A held chat's deadline moves to the later one. One timer per chat.
    pub(in crate::hub) fn bridge_rate_limited(
        self: &Arc<Self>,
        session: &Arc<Session>,
        turn_id: Option<&str>,
        error: &str,
    ) {
        let now = now_ms();
        let spawn = {
            let mut all = holds();
            let hold = all.entry(session.id.clone()).or_default();
            let wait =
                hold.last_ms.saturating_mul(2).clamp(min_hold_ms(), MAX_HOLD_MS.max(min_hold_ms()));
            hold.last_ms = wait;
            let reset = super::super::auto_resume::reset_hint::reset_at(error, None, now)
                .filter(|&at| at > now);
            let until = reset.unwrap_or(now.saturating_add(wait)).max(hold.until.unwrap_or(0));
            hold.until = Some(until);
            self.append(
                session,
                "mux",
                "rate_limit_held",
                json!({"turnId": turn_id, "until": until, "bridged": true, "error": error}),
            );
            !std::mem::replace(&mut hold.timer, true)
        };
        if spawn {
            let (hub, session) = (self.clone(), session.clone());
            self.scope.spawn_until_cancelled("bridge-rate-hold", async move {
                hub.bridge_hold_timer(&session).await;
            });
        }
    }

    async fn bridge_hold_timer(self: &Arc<Self>, session: &Arc<Session>) {
        let held = loop {
            let (until, wake) = {
                let mut all = holds();
                let Some(hold) = all.get_mut(&session.id) else { return };
                match hold.until {
                    Some(until) if until > now_ms() => (until, hold.wake.clone()),
                    _ => {
                        hold.until = None;
                        hold.timer = false;
                        break std::mem::take(&mut hold.held);
                    }
                }
            };
            let sleep = tokio::time::sleep(Duration::from_millis(until.saturating_sub(now_ms())));
            tokio::select! {
                () = sleep => {}
                () = wake.notified() => {}
            }
        };
        self.release_bridge_hold(session, held).await;
    }

    /// The reset came: the app gets one message, the line and every held one.
    async fn release_bridge_hold(self: &Arc<Self>, session: &Arc<Session>, held: Vec<Parked>) {
        let ids: Vec<String> = held.iter().map(|p| p.prompt_id.clone()).collect();
        let fail = |e: &str| {
            let mut all = deliveries();
            for id in &ids {
                let key = all.of_prompt(&session.id, id).map(|(k, _)| k.clone());
                if let Some(p) = key.and_then(|k| all.by_uuid.remove(&k)) {
                    p.turn.send_replace(Some(Err(e.to_owned())));
                }
            }
        };
        let Ok(target) = self.bridge_target(session).await else {
            fail("the app no longer runs this chat");
            self.append(
                session,
                "mux",
                "rate_limit_lifted",
                json!({"bridged": true, "held": ids, "delivered": false}),
            );
            return;
        };
        let mut wire = CONTINUE_LINE.to_owned();
        for p in &held {
            wire.push_str("\n\n---\n\n");
            wire.push_str(&p.wire);
        }
        let (prompt_id, riders) = match ids.split_first() {
            Some((first, rest)) => (first.clone(), rest.to_vec()),
            None => (format!("bridge-resume-{}", uuid::Uuid::now_v7()), Vec::new()),
        };
        let uuid = uuid::Uuid::now_v7().to_string();
        {
            let mut all = deliveries();
            // The first held prompt's kept delivery becomes the one that goes: its key is now the
            // uuid the app's transcript line carries, so the watch shows the turn as that prompt.
            let parked = all.of_prompt(&session.id, &prompt_id).map(|(k, _)| k.clone());
            match parked.and_then(|k| all.by_uuid.remove(&k)) {
                Some(mut p) => {
                    p.wire = wire.clone();
                    p.shown = false;
                    all.by_uuid.insert(uuid.clone(), p);
                }
                None => {
                    let _ = all.claim(
                        uuid.clone(),
                        &session.id,
                        &prompt_id,
                        CONTINUE_LINE,
                        &wire,
                        false,
                    );
                }
            }
            all.ride(&session.id, &prompt_id, riders);
        }
        let sender = held.first().map_or("acpmux", |p| p.sender.as_str());
        if let Err(e) = target.deliver(&wire, &[], &uuid, sender).await {
            if let Some(p) = deliveries().by_uuid.remove(&uuid) {
                p.turn.send_replace(Some(Err(e.clone())));
            }
            fail(&e);
            self.append(
                session,
                "mux",
                "rate_limit_lifted",
                json!({"bridged": true, "held": ids, "delivered": false, "error": e}),
            );
            return;
        }
        if let Some(known) = delivered_ids().get_mut(&session.id) {
            known.extend(ids.iter().cloned());
        }
        for id in ids.iter().cloned().chain(ids.is_empty().then(|| prompt_id.clone())) {
            self.append(session, "mux", "bridge_delivered", json!({"promptId": id, "uuid": uuid}));
        }
        self.append(
            session,
            "mux",
            "rate_limit_lifted",
            json!({"bridged": true, "held": ids, "promptId": prompt_id, "delivered": true}),
        );
    }
}
