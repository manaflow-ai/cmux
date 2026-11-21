//! Part of `Hub`; see `hub/mod.rs`. The skill distiller's offer and its answer
//! (`skill_distill.rs`): a completed turn writes its chat's task shape to the folder's record,
//! once, at the turn's end. When the chat makes a pattern with two others, the skill is drafted
//! once by the chat's own harness (one headless completion, `complete`; the shapes' own draft
//! where none can answer), kept with the pattern, and logged as a `mux` `skill_offer` record
//! `{offerId, name, description, body, count, chats, drafted, harness?}`. The person's Save or
//! Not now (`_acpmux/skill_resolve`, `server/skill_distill.rs`) writes `SKILL.md` into their
//! skills folder or drops the pattern for good, and logs `skill_resolved` `{offerId, action,
//! name?, path?}`.

use super::*;
use crate::complete::{CompleteError, Request};
use crate::skill_distill::{self as distill, Draft, Records, Shape};
use std::path::PathBuf;

/// Where every folder's record is kept.
fn records() -> Records {
    Records::at(crate::config::home().join("skill-patterns"))
}

/// The draft's answer is cut to about this many tokens.
const DRAFT_TOKENS: u32 = 600;
/// The longest a draft may take.
const DRAFT_TIMEOUT_MS: u64 = 45_000;

impl Hub {
    /// A completed turn of `session` ran `shape`: its folder's record has it, and a pattern it
    /// makes now is drafted and offered. Off the turn's path.
    pub(super) fn record_task_shape(self: &Arc<Self>, session: &Arc<Session>, shape: Shape) {
        let hub = self.clone();
        let session = session.clone();
        tokio::spawn(async move {
            let meta = session.meta();
            let cwd = meta.cwd.clone();
            if !super::memory_inbox::is_project(&cwd) {
                return;
            }
            // A turn with no tool runs and a chat never asked anything by a person add nothing.
            if shape.steps.is_empty() && shape.prompt.is_empty() {
                return;
            }
            let offer_id = uuid::Uuid::now_v7().to_string();
            let found = {
                let (cwd, id, offer_id) = (cwd.clone(), session.id.clone(), offer_id.clone());
                tokio::task::spawn_blocking(move || {
                    records().change(&cwd, |record| {
                        record.update(shape);
                        record.claim(&id, &offer_id)
                    })
                })
                .await
            };
            let Ok(Some(found)) = found else { return };
            let (draft, harness) = hub.draft_skill(&meta.harness, &found.chats).await;
            {
                let (cwd, offer_id, draft) = (cwd.clone(), offer_id.clone(), draft.clone());
                let kept = tokio::task::spawn_blocking(move || {
                    records().change(&cwd, |record| {
                        if let Some(p) = record.pattern_mut(&offer_id) {
                            p.draft = Some(draft);
                        }
                    });
                })
                .await;
                if kept.is_err() {
                    return;
                }
            }
            let chats: Vec<Value> = found
                .chats
                .iter()
                .map(|c| json!({"sessionId": c.session, "prompt": c.prompt}))
                .collect();
            let mut record = json!({
                "offerId": offer_id,
                "name": draft.name,
                "description": draft.description,
                "body": draft.body,
                "count": found.chats.len(),
                "chats": chats,
                "drafted": draft.drafted,
            });
            if let (Some(o), Some(h)) = (record.as_object_mut(), harness) {
                o.insert("harness".into(), Value::String(h));
            }
            hub.append(&session, "mux", "skill_offer", record);
        });
    }

    /// The skill `chats` share, from harness `harness` (else the default) in one headless
    /// completion, or from the shapes when none here can answer; the harness that wrote it.
    async fn draft_skill(
        self: &Arc<Self>,
        harness: &str,
        chats: &[Shape],
    ) -> (Draft, Option<String>) {
        let ready = match self.completion_ready(Some(harness)).await {
            Ok(name) => Ok(name),
            Err(
                CompleteError::UnknownHarness(_)
                | CompleteError::Unsupported { .. }
                | CompleteError::NotInstalled { .. },
            ) => self.completion_ready(None).await,
            Err(e) => Err(e),
        };
        let Ok(name) = ready else { return (distill::shapes_draft(chats), None) };
        let req = Request {
            prompt: distill::draft_prompt(chats),
            harness: Some(name.clone()),
            model: None,
            max_tokens: DRAFT_TOKENS,
            timeout: std::time::Duration::from_millis(DRAFT_TIMEOUT_MS),
        };
        let answer = match self.complete_request(&req).await {
            Ok(reply) => reply.get("text").and_then(Value::as_str).unwrap_or_default().to_owned(),
            Err(e) => {
                tracing::debug!(reason = e.reason(), "skill draft: harness did not answer");
                String::new()
            }
        };
        match distill::parse_draft(&answer) {
            Some(draft) => (draft, Some(name)),
            None => (distill::shapes_draft(chats), None),
        }
    }

    /// The person's answer to skill offer `offer_id` of `session`: `save` writes the skill (the
    /// person's edits of `name`, `description` and `body`, else the draft's) into their skills
    /// folder; `dismiss` drops the pattern. Either way it is never offered again.
    pub(crate) async fn skill_resolve(
        &self,
        session: &Arc<Session>,
        offer_id: &str,
        action: &str,
        edits: (Option<String>, Option<String>, Option<String>),
    ) -> Result<Value, RpcError> {
        let cwd = session.meta().cwd;
        let dir = crate::agent_guidance::user_skills_dir();
        let resolved = {
            let offer_id = offer_id.to_owned();
            let action = action.to_owned();
            tokio::task::spawn_blocking(move || {
                resolve_blocking(&cwd, &offer_id, &action, dir, edits)
            })
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?
        };
        let (name, path) = resolved.map_err(RpcError::invalid_params)?;
        let mut record = json!({"offerId": offer_id, "action": action});
        if let Some(o) = record.as_object_mut() {
            if let Some(name) = name {
                o.insert("name".into(), Value::String(name));
            }
            if let Some(path) = path {
                o.insert("path".into(), Value::String(path.to_string_lossy().into_owned()));
            }
        }
        self.append(session, "mux", "skill_resolved", record.clone());
        Ok(record)
    }
}

/// [`Hub::skill_resolve`]'s file work: the saved skill's name and path, None for a dismissal.
fn resolve_blocking(
    cwd: &std::path::Path,
    offer_id: &str,
    action: &str,
    dir: Option<PathBuf>,
    (name, description, body): (Option<String>, Option<String>, Option<String>),
) -> Result<(Option<String>, Option<PathBuf>), String> {
    records().change(cwd, |record| {
        let pattern = record
            .pattern_mut(offer_id)
            .ok_or_else(|| "this offer is no longer open".to_owned())?;
        if pattern.state != "offered" {
            return Err(format!("this offer was {} already", pattern.state));
        }
        match action {
            "dismiss" => {
                pattern.state = "dismissed".into();
                Ok((None, None))
            }
            "save" => {
                let draft = pattern
                    .draft
                    .clone()
                    .ok_or_else(|| "the skill is still drafting".to_owned())?;
                let name = name.unwrap_or(draft.name);
                let description = description.unwrap_or(draft.description);
                let body = body.unwrap_or(draft.body);
                let dir = dir.ok_or_else(|| "this machine has no skills folder".to_owned())?;
                let path = distill::write_skill(&dir, name.trim(), &description, &body)?;
                pattern.state = "saved".into();
                Ok((Some(name.trim().to_owned()), Some(path)))
            }
            other => Err(format!("action is save or dismiss, not {other}")),
        }
    })
}
