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
        source.meta.lock().unwrap_or_else(|e| e.into_inner()).fork_requests.insert(
            request.to_owned(),
            ForkRequest { prompt_id: prompt.to_owned(), child_id: id.clone() },
        );
        // Reserve durably before any native copy or new session. The chat's ordered writer
        // commits it, so no older copy can be written after it. Keep the in-memory
        // reservation on an I/O error too: a failed write may have reached storage.
        self.write_meta(source)
            .and_then(|()| self.store.flush_session(&source.id))
            .map_err(|e| refused("fork.incomplete", &e.to_string()))?;
        let child = admitted
            .run(self.fork_with_boundary(
                source,
                None,
                None,
                Default::default(),
                None,
                boundary.through_seq,
                Some((id, boundary)),
                false,
                None,
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
        let shown_through = shown_through(&meta);
        self.store
            .scan_strict(&source.id, 0, &mut |event| {
                if event.seq > meta.last_seq {
                    return false;
                }
                if event.seq != next && !skips_shown(event.seq, next, shown_through) {
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
        if !complete
            || next != meta.last_seq + 1
            || !trusted_start
            || external
            || !self.complete_ancestry(&meta)
        {
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
        // An `unverified` prompt names no other sender: it is edited as an unnamed one was.
        let provenance = msg.pointer("/_meta/provenance");
        if msg.get("steer").is_some()
            || (provenance.is_some() && !crate::prompt_provenance::is_unverified(provenance))
        {
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

    // Ordinary forks copy conversation records, not adoption/import markers. A verified
    // parent link proves ownership, not that its inherited history starts at the first turn.
    // Follow every link and fail closed when any ancestor is missing or incomplete.
    fn complete_ancestry(&self, source: &SessionMeta) -> bool {
        let mut meta = source.clone();
        let mut seen = std::collections::HashSet::from([meta.id.clone()]);
        while let Some(parent) = meta.parent_id.as_deref() {
            if meta.fork_parent_verified != Some(true) || !seen.insert(parent.to_owned()) {
                return false;
            }
            let Ok(Some(ancestor)) = self.store.load(parent) else { return false };
            let mut next = 1;
            let mut origin = false;
            let mut complete = true;
            let shown_through = shown_through(&ancestor);
            if self
                .store
                .scan_strict(parent, 0, &mut |event| {
                    if event.seq > ancestor.last_seq {
                        return false;
                    }
                    complete &= event.seq == next || skips_shown(event.seq, next, shown_through);
                    next = event.seq + 1;
                    if event.dir == "mux" {
                        origin |= matches!(event.kind.as_str(), "created" | "forked");
                        complete &= !matches!(event.kind.as_str(), "adopted" | "imported");
                    }
                    true
                })
                .is_err()
                || !complete
                || !origin
                || next != ancestor.last_seq + 1
            {
                return false;
            }
            meta = ancestor;
        }
        true
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

/// The seq through which a fork shows its chat's history by reference (`store/fork_view.rs`), or
/// holds it since it was written into its log (`history_kept_through`), or 0: those records are
/// the chat's history kinds under the chat's own seqs, so they skip seqs, and `complete_ancestry`
/// proves the chat's own log whole.
fn shown_through(meta: &SessionMeta) -> u64 {
    meta.history_from.as_ref().map(|r| r.through_seq).or(meta.history_kept_through).unwrap_or(0)
}

/// Whether `seq`, read where `next` was due, is a skip inside the history a fork shows by
/// reference: forward only, and no further than the fork's own first record.
fn skips_shown(seq: u64, next: u64, shown_through: u64) -> bool {
    seq > next && seq <= shown_through + 1
}

#[cfg(test)]
mod shown_tests {
    use super::*;

    /// A fork whose referenced history was written into its log keeps that history under the
    /// chat's seqs, and Edit and resend still proves its log whole after a restart, when its meta
    /// names no chat any more (review of #37020: the proof refused it).
    #[test]
    fn history_written_into_a_fork_keeps_its_skips_allowed() {
        let mut meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "fork", "name": "fork", "harness": "fake",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap();
        assert_eq!(shown_through(&meta), 0);
        meta.history_kept_through = Some(20);
        assert_eq!(shown_through(&meta), 20);
        // The chat's records at 2, 4, 5, ... through 20, then the fork's own at 21.
        assert!(skips_shown(4, 3, shown_through(&meta)));
        assert!(skips_shown(21, 19, shown_through(&meta)));
        assert!(!skips_shown(23, 21, shown_through(&meta)), "a skip past them is a gap");
    }
}
