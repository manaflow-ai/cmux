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

/// What the chat's log says about offer `id`.
struct LogRead {
    /// The person's first prompt with text: never an agent's or a peer's, never an empty one.
    first: Option<String>,
    /// The chat's corrections and the offer, rebuilt for an offer an earlier daemon run logged
    /// whose rewrite was not made yet.
    restored: Option<prompt_coach::Coach>,
}

/// The text of a person's prompt record: one with no provenance (`prompt_provenance::marked`),
/// with text in it.
fn person_text(msg: &Value) -> Option<&str> {
    if msg.pointer("/_meta/provenance").is_some() {
        return None;
    }
    msg.get("text").and_then(Value::as_str).filter(|t| !t.trim().is_empty())
}

/// One read of chat `sid`'s prompts and coach records, off the async threads.
fn read_log(hub: &Hub, sid: &str, id: &str) -> LogRead {
    let mut first = None;
    let mut replay = prompt_coach::Coach::default();
    let (mut offered, mut made) = (false, false);
    let kinds = ["user_message", "coach_offer", "coach"];
    let _ = hub.store.scan_kinds(sid, &kinds, &mut |e| {
        let this = e.msg.get("coachId").and_then(Value::as_str) == Some(id);
        match e.kind.as_str() {
            "user_message" => {
                if let Some(text) = person_text(&e.msg) {
                    first.get_or_insert_with(|| text.to_owned());
                    if !offered {
                        replay.prompt(text);
                    }
                }
            }
            "coach_offer" if this => {
                offered = true;
                replay.offer(id.to_owned());
            }
            "coach" if this => made = true,
            _ => {}
        }
        !made
    });
    LogRead { first, restored: (offered && !made).then_some(replay) }
}

impl Hub {
    /// A person's prompt to `session` (`server/requests.rs`), checked once as it is sent; a retry
    /// of its `promptId` is not counted again.
    pub(crate) fn coach_prompt(&self, session: &Session, text: &str, prompt_id: Option<&str>) {
        session.coach.lock().unwrap_or_else(|e| e.into_inner()).prompt_once(text, prompt_id);
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
        let read = {
            let hub = self.clone();
            let sid = session.id.clone();
            let id = coach_id.to_owned();
            tokio::task::spawn_blocking(move || read_log(&hub, &sid, &id)).await.ok()
        };
        let Some(read) = read else {
            if ask.is_some() {
                session.coach.lock().unwrap_or_else(|e| e.into_inner()).ask_failed();
            }
            return Ok(json!({"made": false}));
        };
        let ask = match ask {
            Some(ask) => Some(ask),
            // An offer an earlier daemon run logged: its corrections are rebuilt from the log,
            // unless its rewrite was made already or another request rebuilt it meanwhile.
            None => match read.restored {
                Some(restored) => {
                    let mut coach = session.coach.lock().unwrap_or_else(|e| e.into_inner());
                    if coach.offered() == Some(coach_id) {
                        None
                    } else {
                        *coach = restored;
                        coach.take_ask(coach_id)
                    }
                }
                None => None,
            },
        };
        let Some((corrections, count)) = ask else { return Ok(json!({"made": false})) };
        let Some(first) = read.first else {
            session.coach.lock().unwrap_or_else(|e| e.into_inner()).ask_failed();
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

    /// Forgets `id`'s coach state, as a daemon restart does (tests).
    #[doc(hidden)]
    pub fn forget_coach(&self, id: &str) {
        if let Ok(session) = self.resolve(id) {
            *session.coach.lock().unwrap_or_else(|e| e.into_inner()) = Default::default();
        }
    }

    /// Writes prompt coach rewrites with `rewriter` instead of the small model (tests).
    #[doc(hidden)]
    pub fn set_coach_rewriter(&self, rewriter: Option<CoachRewriter>) {
        *self.coach_rewriter.lock().unwrap_or_else(|e| e.into_inner()) = rewriter;
    }
}

#[cfg(test)]
mod tests {
    use super::person_text;
    use serde_json::json;

    /// Every card record a chat client draws under a turn reaches it: a `transcript` page or
    /// stream carries only the mux kinds `paging.rs` lists.
    #[test]
    fn the_card_records_are_transcript_records() {
        for kind in ["recap", "memory_offer", "memory_resolved", "coach_offer", "coach"] {
            assert!(super::super::paging::TRANSCRIPT_MUX_KINDS.contains(&kind), "{kind}");
        }
    }

    /// The rewrite starts from the person's first prompt with text: an agent's or a peer's
    /// message (it has a provenance) and an empty, attachment-only prompt are skipped.
    #[test]
    fn only_a_persons_prompt_with_text_counts() {
        assert_eq!(person_text(&json!({"text": "add a toggle"})), Some("add a toggle"));
        let person = json!({"text": "hi", "_meta": {"origin": {"actor": "person"}}});
        assert_eq!(person_text(&person), Some("hi"));
        let agent = json!({"text": "do X", "_meta": {"provenance": {"kind": "agent"}}});
        assert_eq!(person_text(&agent), None);
        assert_eq!(person_text(&json!({"text": "  "})), None);
        assert_eq!(person_text(&json!({"images": []})), None);
    }
}
