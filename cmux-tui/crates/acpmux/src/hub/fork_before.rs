//! Authoritative prompt boundaries and durable request reservations for Edit and Resend.
use super::*;
use crate::store::{ForkBefore, ForkRequest};

pub(crate) fn refused(reason: &str, why: &str) -> RpcError {
    RpcError::invalid_params(format!("{reason}: {why}")).with_data(json!({"reason": reason}))
}

impl Hub {
    pub(crate) async fn fork_before(
        self: &Arc<Self>,
        source: &Arc<Session>,
        prompt: &str,
        request: &str,
        ask: super::admission::Ask<'_>,
    ) -> Result<(Arc<Session>, Option<Value>), RpcError> {
        let _fork = source.fork_lock.lock().await;
        self.session_log(source).await;
        // The parent's reservation survives deletion of its child. An incomplete operation
        // never allocates another child. Guard checks run before this lookup on every retry.
        if let Some(saved) = source.meta().fork_requests.get(request) {
            if saved.prompt_id != prompt {
                return Err(refused(
                    "fork.request_conflict",
                    "requestId already names another boundary",
                ));
            }
            let child = self.resolve(&saved.child_id).map_err(|_| {
                refused(
                    "fork.incomplete",
                    "the reserved child is unavailable; no replacement was created",
                )
            })?;
            let meta = child.meta();
            if child.id != saved.child_id
                || meta.parent_id.as_deref() != Some(source.id.as_str())
                || !meta
                    .fork_before
                    .is_some_and(|b| b.ready && b.request_id == request && b.prompt_id == prompt)
            {
                return Err(refused(
                    "fork.incomplete",
                    "the reserved fork did not finish; no replacement was created",
                ));
            }
            return Ok((child, None));
        }
        let harness = source.meta().harness;
        let supported = {
            let config = self.config.read().await;
            config.profile(&harness).and_then(|p| crate::config::turn_cut(&harness, p)).is_some()
        };
        if !supported {
            return Err(refused("fork.unsupported", "beforePromptId needs a Claude or Codex chat"));
        }
        let (hub, original, prompt_id) = (self.clone(), source.clone(), prompt.to_owned());
        let mut boundary =
            tokio::task::spawn_blocking(move || hub.prompt_boundary(&original, &prompt_id))
                .await
                .map_err(|e| RpcError::internal(e.to_string()))??;
        boundary.request_id = request.to_owned();
        let admitted = self.admit_new(ask).await?;
        let warning = admitted.warning.clone();
        let id = uuid::Uuid::now_v7().to_string();
        {
            let mut meta = source.meta.lock().unwrap_or_else(|e| e.into_inner());
            meta.fork_requests.insert(
                request.to_owned(),
                ForkRequest { prompt_id: prompt.to_owned(), child_id: id.clone() },
            );
            // Reserve durably before any native copy or new session. Keep the in-memory
            // reservation on an I/O error too: a failed write may have reached storage.
            self.store
                .save(&meta)
                .and_then(|()| self.store.flush_session(&source.id))
                .map_err(|e| refused("fork.incomplete", &e.to_string()))?;
        }
        let child = admitted
            .run(self.fork_with_boundary(
                source,
                None,
                None,
                Default::default(),
                None,
                boundary.through_seq,
                Some((id, boundary)),
            ))
            .await?;
        Ok((child, warning))
    }

    fn prompt_boundary(&self, source: &Session, prompt: &str) -> Result<ForkBefore, RpcError> {
        let _append = source.append_lock.lock().unwrap_or_else(|e| e.into_inner());
        let meta = source.meta();
        let mut next = 1;
        let mut complete = true;
        let mut trusted_start = false;
        let mut external = false;
        let mut users = 0;
        let mut last_user: Option<(u64, String)> = None;
        let mut result: Option<(u64, String)> = None;
        let mut found = Vec::new();
        self.store
            .scan_strict(&source.id, 0, &mut |event| {
                if event.seq > meta.last_seq {
                    return false;
                }
                if event.seq != next {
                    complete = false;
                }
                next = event.seq + 1;
                if event.dir != "mux" {
                    return true;
                }
                match event.kind.as_str() {
                    "created" => trusted_start = true,
                    "forked" if meta.fork_parent_verified == Some(true) => trusted_start = true,
                    "adopted" | "imported" => external = true,
                    "turn_result" => {
                        result = event
                            .msg
                            .get("turnId")
                            .and_then(Value::as_str)
                            .map(|turn| (event.seq, turn.to_owned()));
                    }
                    "user_message" => {
                        if event.msg.get("promptId").and_then(Value::as_str) == Some(prompt) {
                            let previous = match (&last_user, &result) {
                                (Some((user_seq, turn)), Some((seq, ended)))
                                    if user_seq < seq && turn == ended =>
                                {
                                    Some(*seq)
                                }
                                _ => None,
                            };
                            found.push((event.seq, users, previous, event.msg.clone()));
                        }
                        users += 1;
                        last_user = event
                            .msg
                            .get("turnId")
                            .and_then(Value::as_str)
                            .map(|turn| (event.seq, turn.to_owned()));
                    }
                    _ => {}
                }
                true
            })
            .map_err(|e| refused("fork.unreconstructable", &e.to_string()))?;
        if !complete || next != meta.last_seq + 1 || !trusted_start || external {
            return Err(refused(
                "fork.unreconstructable",
                "the complete original conversation cannot be proven from this log",
            ));
        }
        if found.len() > 1 {
            return Err(refused(
                "fork.ambiguous_prompt",
                "promptId names more than one recorded prompt",
            ));
        }
        let (seq, before, through, msg) = found.pop().ok_or_else(|| {
            refused("fork.unknown_prompt", "promptId is not recorded in this session")
        })?;
        if msg.get("steer").is_some() || msg.pointer("/_meta/provenance").is_some() {
            return Err(refused(
                "fork.unsupported",
                "steered or synthesized prompts cannot be edited this way",
            ));
        }
        if (before > 0 && through.is_none())
            || msg.get("turnId").and_then(Value::as_str).is_none()
            || !self.reconstructable_prompt(&source.id, &msg)
        {
            return Err(refused(
                "fork.unreconstructable",
                "the prompt, its attachments, or its preceding completed turn cannot be reconstructed",
            ));
        }
        Ok(ForkBefore {
            prompt_id: prompt.to_owned(),
            request_id: String::new(),
            prompt_seq: seq,
            through_seq: through,
            ready: false,
        })
    }

    fn reconstructable_prompt(&self, source: &str, msg: &Value) -> bool {
        if msg.get("hiddenContext").is_some() {
            return false;
        }
        let image = |part: &Value| {
            part.get("persisted") != Some(&Value::Bool(false))
                && part
                    .get("id")
                    .and_then(Value::as_str)
                    .is_some_and(|id| self.prompt_image(source, id).is_ok())
        };
        if let Some(parts) = msg.get("inlineParts") {
            return parts.as_array().is_some_and(|parts| {
                !parts.is_empty()
                    && parts.iter().all(|part| match part.get("kind").and_then(Value::as_str) {
                        Some("text" | "pasted") => {
                            part.get("text").and_then(Value::as_str).is_some()
                        }
                        Some("image") => image(part),
                        Some("file") => {
                            part.get("text").and_then(Value::as_str).is_some()
                                || part
                                    .get("uri")
                                    .and_then(Value::as_str)
                                    .is_some_and(|uri| !uri.is_empty())
                        }
                        _ => false,
                    })
            });
        }
        let images = msg.get("images").and_then(Value::as_array);
        (msg.get("text").and_then(Value::as_str).is_some_and(|s| !s.is_empty())
            || images.is_some_and(|images| !images.is_empty()))
            && images.is_none_or(|images| images.iter().all(image))
    }
}
