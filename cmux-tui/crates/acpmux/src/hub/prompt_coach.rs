//! Part of `Hub`; see `hub/mod.rs`. The prompt coach's offer and its rewrite (`prompt_coach.rs`):
//! a completed turn after enough corrections logs a `mux` `coach_offer` record `{coachId,
//! corrections}` once per chat, with no model call; the chat page that shows it asks for the
//! rewrite (`_acpmux/prompt_coach`, `server/prompt_coach.rs`), which one small-model call makes
//! from the chat's first prompt and the corrections, logged as `coach` `{coachId, firstPrompt,
//! rewrite, corrections}`.

use super::*;
use crate::prompt_coach;
use std::time::Duration;

/// The longest the rewrite's model call runs.
const TIMEOUT: Duration = Duration::from_secs(60);
/// The rewrite's answer, in tokens (`complete::finish` cuts it to about that).
const MAX_TOKENS: u32 = 1024;

/// What writes the rewrite in place of the small model (tests).
pub type CoachRewriter = Arc<dyn Fn(String) -> Option<String> + Send + Sync>;

impl Hub {
    /// A person's prompt to `session` (`server/requests.rs`), checked once as it is sent.
    pub(crate) fn coach_prompt(&self, session: &Session, text: &str) {
        session.coach.lock().unwrap_or_else(|e| e.into_inner()).prompt(text);
    }

    /// A turn of `session` ended: once the chat qualifies, its offer is logged, unless an earlier
    /// daemon run logged one already. Off the turn's path; no model is asked.
    pub(super) fn coach_turn_ended(self: &Arc<Self>, session: &Arc<Session>, completed: bool) {
        let id = {
            let mut coach = session.coach.lock().unwrap_or_else(|e| e.into_inner());
            if !coach.turn_ended(completed) {
                return;
            }
            let id = uuid::Uuid::now_v7().to_string();
            coach.offer(id.clone());
            id
        };
        let hub = self.clone();
        let session = session.clone();
        tokio::spawn(async move {
            let earlier = {
                let hub = hub.clone();
                let sid = session.id.clone();
                tokio::task::spawn_blocking(move || {
                    let mut found = false;
                    let _ = hub.store.scan_kinds(&sid, &["coach_offer"], &mut |_| {
                        found = true;
                        false
                    });
                    found
                })
                .await
                .unwrap_or(true)
            };
            if earlier {
                return;
            }
            let count = session.coach.lock().unwrap_or_else(|e| e.into_inner()).count();
            hub.append(
                &session,
                "mux",
                "coach_offer",
                json!({"coachId": id, "corrections": count}),
            );
        });
    }

    /// `_acpmux/prompt_coach`: the rewrite of `session`'s offer `coach_id`, made once and logged
    /// as a `coach` record. `{made: false}` when there is nothing to make (made already, another
    /// offer, an offer of an earlier daemon run, or the model gave no answer).
    pub(crate) async fn prompt_coach(
        self: &Arc<Self>,
        session: &Arc<Session>,
        coach_id: &str,
    ) -> Result<Value, RpcError> {
        let ask = session.coach.lock().unwrap_or_else(|e| e.into_inner()).take_ask(coach_id);
        let Some((corrections, count)) = ask else { return Ok(json!({"made": false})) };
        let first = {
            let hub = self.clone();
            let sid = session.id.clone();
            tokio::task::spawn_blocking(move || {
                let mut first = None;
                let _ = hub.store.scan_kinds(&sid, &["user_message"], &mut |e| {
                    first = e.msg.get("text").and_then(Value::as_str).map(str::to_owned);
                    first.is_none()
                });
                first
            })
            .await
            .ok()
            .flatten()
        };
        let Some(first) = first.filter(|f| !f.trim().is_empty()) else {
            return Ok(json!({"made": false}));
        };
        let prompt = prompt_coach::rewrite_prompt(&first, &corrections);
        let rewriter = self.coach_rewriter.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let answer = match rewriter {
            Some(rewrite) => rewrite(prompt),
            None => {
                let harness = session.meta().harness;
                match self.complete_own(Some(&harness), prompt, MAX_TOKENS, TIMEOUT).await {
                    Ok(text) => Some(text),
                    Err(e) => {
                        tracing::info!(session = %session.id, reason = e.reason(), "prompt coach: no rewrite");
                        None
                    }
                }
            }
        };
        let Some(rewrite) = answer.as_deref().and_then(prompt_coach::clean_rewrite) else {
            session.coach.lock().unwrap_or_else(|e| e.into_inner()).ask_failed();
            return Ok(json!({"made": false}));
        };
        let first = prompt_coach::cut(&first, prompt_coach::MAX_PROMPT_CHARS);
        self.append(
            session,
            "mux",
            "coach",
            json!({
                "coachId": coach_id,
                "firstPrompt": first,
                "rewrite": rewrite,
                "corrections": count,
            }),
        );
        Ok(json!({"made": true}))
    }

    /// Writes prompt coach rewrites with `rewriter` instead of the small model (tests).
    #[doc(hidden)]
    pub fn set_coach_rewriter(&self, rewriter: Option<CoachRewriter>) {
        *self.coach_rewriter.lock().unwrap_or_else(|e| e.into_inner()) = rewriter;
    }
}
