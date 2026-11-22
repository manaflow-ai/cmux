//! `_acpmux/retry {atReset: true}`: the person's one-shot resume of a usage-limited failed turn
//! at the reset its provider reported (teardown row 13, Leo: "select the thing and then start
//! the thing"). The webview arms it from the failed turn; acpmux owns its schedule.
//!
//! - Opt-in: offered (the row's `resumeAtReset`) only while nothing goes on by itself. An
//!   automatic continuation that waits (`Mark`), or a rate hold whose continuation waits
//!   (`rate_hold.rs`), already resumes at the reset: it is never offered over one, so it never
//!   sends a second prompt. The automatic defaults (`autoResumeDelaysMs`) do not change.
//! - Bound to the failed turn: its identity is that turn's id and the prompt id it sends, the
//!   next attempt of the failed prompt (`P~resume-n`). Recorded as `resume_at_reset`
//!   (`state: armed | cancelled | fired | failed`), restored across a daemon restart.
//! - At most once: firing takes the armed slot and records `fired` before it sends through
//!   [`Hub::retry_turn`], whose prompt id is the same attempt's. A restart after `fired` never
//!   arms it again.
//! - Cancelled (`why`) by the person (`person`), new work in the chat (a turn or a queued prompt:
//!   `new_work`), a pending permission (`permission`), archive (`archived`), close (`closed`), or a
//!   run that superseded it (another turn's result, an automatic continuation: `superseded`).
//! - A reset the provider did not report is never guessed: the row says `unknown_reset` and
//!   arming is refused (`retry.at_reset.unknown_reset`), so the person retries by hand.
use super::retry_turn::{RetryBy, refused};
use super::{SUFFIX, is_pending, split_attempt, still_cut_by};
use crate::hub::{Control, Hub, Session, now_ms};
use crate::protocol::session::{ResumeAtReset, ResumeAtResetState, RetryKind, RetryResult};
use crate::rpc::RpcError;
use crate::store::{EventRecord, SessionMeta};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

/// The record kind of every state change.
pub(crate) const RECORD: &str = "resume_at_reset";

/// How often an armed resume looks for what cancels it while it waits.
const TICK_MS: u64 = 2_000;
/// After the reset, before it sends: the hold's own timer lifts first (`rate_hold.rs`).
const GRACE_MS: u64 = 1_000;

static NEXT_ARM: AtomicU64 = AtomicU64::new(1);

/// The armed resume of one failed turn.
pub(crate) struct Armed {
    /// This arming, so a task left from a cancelled one never fires a later one.
    id: u64,
    turn_id: String,
    /// The prompt id it sends: the next attempt of the failed prompt.
    prompt_id: String,
    resets_at: u64,
    control: Control,
    trust_gate: bool,
    full_access_device: Option<String>,
}

/// The failed turn a resume at the reset may be bound to: `(turn id, failed prompt id, the
/// attempt it would send, the provider's reset)`, or why there is none. `Err(None)`: no
/// usage-limited failed turn at all; `Err(Some(reason))`: one the person cannot arm now.
type Eligible = (String, String, String, Option<u64>);

/// `m` is a copy of the chat's meta, never one `read_meta` holds: the checks lock it again.
fn eligible(
    session: &Session,
    m: &SessionMeta,
    now: u64,
) -> Result<Eligible, Option<&'static str>> {
    let last = m.last_turn.as_ref().ok_or(None)?;
    let field = |k: &str| last.get(k).and_then(Value::as_str);
    if field("status") != Some("failed") {
        return Err(None);
    }
    let (Some(turn_id), Some(failed)) = (field("turnId"), field("promptId")) else {
        return Err(None);
    };
    let error = field("errorText").unwrap_or_default();
    if crate::hub::turn_errors::resume_cause(error, error) != Some("rate_limit") {
        return Err(None);
    }
    if m.status == crate::store::SessionStatus::Closed {
        return Err(Some("closed"));
    }
    if crate::hub::inactive_archive::has_tag(m, crate::hub::plan_build::ARCHIVED_TAG, now) {
        return Err(Some("archived"));
    }
    // Something goes on by itself at the reset: never a second prompt over it.
    if is_pending(session.auto_resume.lock().as_ref()) || session.rate_hold.continues() {
        return Err(Some("already_scheduled"));
    }
    if !still_cut_by(session, turn_id, false) {
        return Err(Some("new_work"));
    }
    if !session.pending_permissions().is_empty() {
        return Err(Some("permission"));
    }
    let reset =
        super::reset_hint::reset_at(error, m.usage_limits.as_ref(), now).filter(|at| *at > now);
    let (root, done) = split_attempt(failed);
    let next = format!("{root}{SUFFIX}{}", done + 1);
    Ok((turn_id.to_owned(), failed.to_owned(), next, reset))
}

fn answer(prompt_id: String, turn_id: String, resets_at: Option<u64>, cancelled: bool) -> Value {
    let result = RetryResult {
        prompt_id,
        turn_id: Some(turn_id),
        kind: RetryKind::AtReset,
        resets_at,
        cancelled,
    };
    serde_json::to_value(result).unwrap_or(Value::Null)
}

impl Hub {
    /// `_acpmux/retry {atReset: true}`: arms the resume of the chat's usage-limited failed turn
    /// at its reported reset, under the caller's rules; with `cancel` cancels the armed one.
    pub async fn resume_at_reset(
        self: &Arc<Self>,
        session: &Arc<Session>,
        by: RetryBy,
        cancel: bool,
    ) -> Result<Value, RpcError> {
        if cancel {
            let armed = self.cancel_resume_at_reset(session, "person");
            return match armed {
                Some((turn_id, prompt_id)) => Ok(answer(prompt_id, turn_id, None, true)),
                None => Err(refused(
                    "retry.at_reset.not_armed",
                    "no resume at the reset is armed in this chat",
                )),
            };
        }
        self.retry_allowed(session, &by).await?;
        let now = now_ms();
        // A copy, not `read_meta`: the checks lock the session's meta again (`still_cut_by`).
        let meta = session.meta();
        let (turn_id, failed, prompt_id, reset) =
            eligible(session, &meta, now).map_err(|why| match why {
                None => refused(
                    "retry.at_reset.not_rate_limited",
                    "the chat's last turn did not fail on a usage limit",
                ),
                Some("already_scheduled") => refused(
                    "retry.at_reset.already_scheduled",
                    "the chat already goes on by itself at the reset",
                ),
                Some("new_work") => super::retry_turn::busy(),
                Some("permission") => refused(
                    "retry.at_reset.permission_pending",
                    "a permission waits for an answer in this chat",
                ),
                Some(why) => refused("retry.at_reset.closed", why),
            })?;
        let Some(resets_at) = reset else {
            return Err(refused(
                "retry.at_reset.unknown_reset",
                "the provider reported no reset time; retry by hand",
            ));
        };
        let id = NEXT_ARM.fetch_add(1, Ordering::SeqCst);
        {
            let mut slot = session.resume_at_reset.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(armed) = slot.as_ref().filter(|a| a.turn_id == turn_id) {
                // Armed already: the same one answers, never a second timer.
                return Ok(answer(armed.prompt_id.clone(), turn_id, Some(armed.resets_at), false));
            }
            *slot = Some(Armed {
                id,
                turn_id: turn_id.clone(),
                prompt_id: prompt_id.clone(),
                resets_at,
                control: by.control,
                trust_gate: by.trust_gate,
                full_access_device: by.full_access_device.clone(),
            });
        }
        self.append(
            session,
            "mux",
            RECORD,
            json!({
                "state": "armed",
                "turnId": turn_id,
                "failedPromptId": failed,
                "promptId": prompt_id,
                "resetsAt": resets_at,
                "control": by.control.as_str(),
                "trustGate": by.trust_gate,
                "fullAccessDevice": by.full_access_device,
            }),
        );
        self.wait_for_reset(session, id);
        Ok(answer(prompt_id, turn_id, Some(resets_at), false))
    }

    /// Cancels the armed resume, if one is, recording `why`: its `(turn id, prompt id)`.
    pub(in crate::hub) fn cancel_resume_at_reset(
        &self,
        session: &Session,
        why: &str,
    ) -> Option<(String, String)> {
        let armed = session.resume_at_reset.lock().unwrap_or_else(|e| e.into_inner()).take()?;
        let msg = json!({"state": "cancelled", "turnId": armed.turn_id, "promptId": armed.prompt_id, "why": why});
        self.append(session, "mux", RECORD, msg);
        Some((armed.turn_id, armed.prompt_id))
    }

    /// The row's `resumeAtReset`: armed, offered, or a usage-limited failure with no reported
    /// reset. Reads nothing unless the last turn failed.
    pub(in crate::hub) fn resume_at_reset_row(
        &self,
        session: &Session,
        m: &SessionMeta,
    ) -> Option<ResumeAtReset> {
        if let Some(armed) =
            session.resume_at_reset.lock().unwrap_or_else(|e| e.into_inner()).as_ref()
        {
            return Some(ResumeAtReset {
                state: ResumeAtResetState::Armed,
                turn_id: armed.turn_id.clone(),
                resets_at: Some(armed.resets_at),
            });
        }
        let (turn_id, _, _, reset) = eligible(session, m, now_ms()).ok()?;
        Some(ResumeAtReset {
            state: if reset.is_some() {
                ResumeAtResetState::Offered
            } else {
                ResumeAtResetState::UnknownReset
            },
            turn_id,
            resets_at: reset,
        })
    }

    /// Why the armed resume `armed` no longer holds, if it does not.
    fn reset_cancel_reason(&self, session: &Session, turn_id: &str) -> Option<&'static str> {
        if session.replaced.load(Ordering::SeqCst) {
            return Some("superseded");
        }
        let now = now_ms();
        let cut = session.read_meta(|m| {
            if m.status == crate::store::SessionStatus::Closed {
                return Some("closed");
            }
            if crate::hub::inactive_archive::has_tag(m, crate::hub::plan_build::ARCHIVED_TAG, now) {
                return Some("archived");
            }
            let last = m.last_turn.as_ref().and_then(|t| t.get("turnId")).and_then(Value::as_str);
            (last != Some(turn_id)).then_some("superseded")
        });
        if cut.is_some() {
            return cut;
        }
        // An automatic continuation took the reset over: it is the one prompt.
        if is_pending(session.auto_resume.lock().as_ref()) || session.rate_hold.continues() {
            return Some("superseded");
        }
        if !still_cut_by(session, turn_id, false) {
            return Some("new_work");
        }
        if !session.pending_permissions().is_empty() {
            return Some("permission");
        }
        None
    }

    /// The armed resume `id`'s wait: it looks for what cancels it every [`TICK_MS`], and at the
    /// reset (and after any hold the account still has) sends once.
    fn wait_for_reset(self: &Arc<Self>, session: &Arc<Session>, id: u64) {
        let (hub, session) = (self.clone(), session.clone());
        // One per armed chat; it ends with the arming, the chat, or the hub.
        self.scope.spawn_until_cancelled("resume-at-reset", async move {
            let mut closed = session.closed.subscribe();
            loop {
                let (turn_id, resets_at) = {
                    let slot = session.resume_at_reset.lock().unwrap_or_else(|e| e.into_inner());
                    match slot.as_ref() {
                        Some(a) if a.id == id => (a.turn_id.clone(), a.resets_at),
                        // Cancelled, or another arming owns the slot now.
                        _ => return,
                    }
                };
                if let Some(why) = hub.reset_cancel_reason(&session, &turn_id) {
                    hub.cancel_armed(&session, id, why);
                    return;
                }
                let now = now_ms();
                let held = session.rate_hold.until().unwrap_or(0);
                let due = resets_at.max(held).saturating_add(GRACE_MS);
                if now >= due {
                    break;
                }
                let wait = (due - now).min(TICK_MS);
                tokio::select! {
                    () = tokio::time::sleep(std::time::Duration::from_millis(wait)) => {}
                    _ = closed.changed() => {}
                }
            }
            hub.fire_resume_at_reset(&session, id).await;
        });
    }

    /// Cancels arming `id` only, recording `why`.
    fn cancel_armed(&self, session: &Session, id: u64, why: &str) {
        let owned = session
            .resume_at_reset
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .is_some_and(|a| a.id == id);
        if owned {
            self.cancel_resume_at_reset(session, why);
        }
    }

    /// Sends arming `id`'s prompt, once: the slot is taken and `fired` recorded first.
    async fn fire_resume_at_reset(self: &Arc<Self>, session: &Arc<Session>, id: u64) {
        let armed = {
            let mut slot = session.resume_at_reset.lock().unwrap_or_else(|e| e.into_inner());
            if slot.as_ref().is_none_or(|a| a.id != id) {
                return;
            }
            slot.take()
        };
        let Some(armed) = armed else { return };
        let fired = json!({"state": "fired", "turnId": armed.turn_id, "promptId": armed.prompt_id});
        self.append(session, "mux", RECORD, fired);
        let by = RetryBy {
            control: armed.control,
            trust_gate: armed.trust_gate,
            full_access_device: armed.full_access_device,
            from: None,
        };
        if let Err(e) = self.retry_turn(session, by).await {
            let reason = e.data.as_ref().and_then(|d| d.get("reason")).cloned();
            let msg = json!({"state": "failed", "turnId": armed.turn_id, "promptId": armed.prompt_id, "reason": reason, "error": e.message});
            self.append(session, "mux", RECORD, msg);
        }
    }

    /// After a restart: the resume the log says is armed for the chat's last turn waits again,
    /// at its recorded reset (sent at once when that has passed and nothing cancels it). Never
    /// one that fired, failed or was cancelled.
    pub(in crate::hub) fn restore_resume_at_reset(self: &Arc<Self>, session: &Arc<Session>) {
        if session.resume_at_reset.lock().unwrap_or_else(|e| e.into_inner()).is_some() {
            return;
        }
        let mut newest = None::<EventRecord>;
        let skip = |_: &[u8], kind: &[u8]| {
            kind != RECORD.as_bytes() && kind != b"turn_started" && kind != b"turn_result"
        };
        let scanned = self.store.scan_back(&session.id, 0, u64::MAX, &skip, &mut |e| {
            if e.kind == RECORD {
                newest = Some(e);
            }
            false
        });
        let Some(e) = newest.filter(|_| scanned.is_ok()) else { return };
        let field = |k: &str| e.msg.get(k).and_then(Value::as_str).map(str::to_owned);
        let (Some("armed"), Some(turn_id), Some(prompt_id), Some(resets_at)) = (
            field("state").as_deref(),
            field("turnId"),
            field("promptId"),
            e.msg.get("resetsAt").and_then(Value::as_u64),
        ) else {
            return;
        };
        let id = NEXT_ARM.fetch_add(1, Ordering::SeqCst);
        {
            let mut slot = session.resume_at_reset.lock().unwrap_or_else(|e| e.into_inner());
            if slot.is_some() {
                return;
            }
            *slot = Some(Armed {
                id,
                turn_id,
                prompt_id,
                resets_at,
                control: Control::from_recorded(e.msg.get("control").and_then(Value::as_str)),
                trust_gate: e.msg.get("trustGate").and_then(Value::as_bool).unwrap_or(true),
                full_access_device: field("fullAccessDevice"),
            });
        }
        self.wait_for_reset(session, id);
    }
}

#[cfg(test)]
#[path = "at_reset_tests.rs"]
mod tests;
