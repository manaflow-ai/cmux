//! The `_acpmux/handoff_*` methods. Every mutation holds `Handoffs::ops`;
//! clients keep `handoffKey`, `draftKey` and `promptId` across uncertain
//! replies and the daemon answers repeats from the record.

use super::{
    CONFLICT, Checkpoint, DROP_START_REPLY_ENV, INVALID, MAX_CAPSULE_BYTES, Record, Side, State,
    not_found, refuse, too_large,
};
use crate::config::PermissionPolicy;
use crate::hub::{Hub, NewRequest, PromptOptions, Session};
use crate::rpc::RpcError;
use crate::store::{EventRecord, now_ms};
use serde_json::{Value, json};
use std::sync::Arc;

fn text_param<'a>(p: &'a Value, key: &str) -> Option<&'a str> {
    p.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

fn required<'a>(p: &'a Value, key: &str) -> Result<&'a str, RpcError> {
    text_param(p, key).ok_or_else(|| RpcError::invalid_params(format!("{key} is required")))
}

fn revision(p: &Value) -> Result<u64, RpcError> {
    p.get("revision")
        .and_then(Value::as_u64)
        .ok_or_else(|| RpcError::invalid_params("revision is required"))
}

fn string_list(v: Option<&Value>, key: &str) -> Result<Option<Vec<String>>, RpcError> {
    let invalid = || RpcError::invalid_params(format!("{key} must be an array of strings"));
    match v {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(a)) => a
            .iter()
            .map(|x| x.as_str().map(str::to_owned).ok_or_else(invalid))
            .collect::<Result<Vec<_>, _>>()
            .map(Some),
        Some(_) => Err(invalid()),
    }
}

/// `checkpoint` as sent: absent (`None`), null (`Some(None)`, which clears
/// it on a draft), or a nonempty ref with `attest: true`.
fn checkpoint_input(v: Option<&Value>) -> Result<Option<Option<String>>, RpcError> {
    match v {
        None => Ok(None),
        Some(Value::Null) => Ok(Some(None)),
        Some(c) => {
            let reference = c.get("ref").and_then(Value::as_str).map(str::trim).unwrap_or("");
            if reference.is_empty() || c.get("attest").and_then(Value::as_bool) != Some(true) {
                return Err(refuse(
                    INVALID,
                    "checkpoint_unattested",
                    "a checkpoint needs a nonempty ref and attest: true",
                    None,
                ));
            }
            Ok(Some(Some(reference.to_owned())))
        }
    }
}

fn now() -> String {
    crate::server::iso(now_ms())
}

fn stamp(reference: String) -> Checkpoint {
    Checkpoint { reference, attested_by: "user".into(), attested_at: now() }
}

/// One step stricter: approve-all, approve-edits, approve-reads, ask, deny-all.
fn narrower_policy(p: PermissionPolicy) -> Option<PermissionPolicy> {
    match p {
        PermissionPolicy::ApproveAll => Some(PermissionPolicy::ApproveEdits),
        PermissionPolicy::ApproveEdits => Some(PermissionPolicy::ApproveReads),
        PermissionPolicy::ApproveReads => Some(PermissionPolicy::Ask),
        PermissionPolicy::Ask => Some(PermissionPolicy::DenyAll),
        PermissionPolicy::DenyAll => None,
    }
}

/// The checkpoint and memory references the user approved, sent as a
/// second prompt block after the capsule text.
fn references(r: &Record) -> Option<String> {
    let mut lines = Vec::new();
    if let Some(c) = &r.checkpoint {
        lines.push(format!(
            "Checkpoint: {} (attested by the user at {})",
            c.reference, c.attested_at
        ));
    }
    if !r.memory_refs.is_empty() {
        lines.push(format!("Memory references: {}", r.memory_refs.join(", ")));
    }
    (!lines.is_empty()).then(|| lines.join("\n"))
}

/// The capsule fields a draft or start carries; `None` keeps the record's.
struct Edit {
    text: Option<String>,
    memory_refs: Option<Vec<String>>,
    checkpoint: Option<Option<String>>,
}

impl Edit {
    fn parse(p: &Value) -> Result<Self, RpcError> {
        let capsule = p.get("capsule").filter(|c| !c.is_null());
        let text = match capsule.and_then(|c| c.get("text")) {
            None | Some(Value::Null) => None,
            Some(Value::String(t)) => Some(t.clone()),
            Some(_) => return Err(RpcError::invalid_params("capsule.text must be a string")),
        };
        if let Some(t) = &text
            && t.len() > MAX_CAPSULE_BYTES
        {
            return Err(too_large(t.len()));
        }
        let memory_refs =
            string_list(capsule.and_then(|c| c.get("memoryRefs")), "capsule.memoryRefs")?;
        let checkpoint = checkpoint_input(p.get("checkpoint"))?;
        Ok(Self { text, memory_refs, checkpoint })
    }

    fn differs(&self, r: &Record) -> bool {
        let current = r.checkpoint.as_ref().map(|c| c.reference.as_str());
        self.text.as_ref().is_some_and(|t| *t != r.text)
            || self.memory_refs.as_ref().is_some_and(|m| *m != r.memory_refs)
            || self.checkpoint.as_ref().is_some_and(|c| c.as_deref() != current)
    }

    fn apply(self, r: &mut Record) {
        if let Some(t) = self.text {
            r.text = t;
        }
        if let Some(m) = self.memory_refs {
            r.memory_refs = m;
        }
        match self.checkpoint {
            Some(Some(reference))
                if r.checkpoint.as_ref().is_some_and(|c| c.reference == reference) => {}
            Some(Some(reference)) => r.checkpoint = Some(stamp(reference)),
            Some(None) => r.checkpoint = None,
            None => {}
        }
    }
}

impl Hub {
    /// `_acpmux/handoff_prepare`: capture the source's context and create
    /// the target (never prompted). The same `handoffKey` returns the same
    /// record.
    pub async fn handoff_prepare(self: &Arc<Self>, p: &Value) -> Result<Value, RpcError> {
        let source_key = required(p, "sessionId")?;
        let harness = required(p, "harness")?;
        let key = required(p, "handoffKey")?;
        let checkpoint = checkpoint_input(p.get("checkpoint"))?.flatten();
        let memory_refs = string_list(p.get("memoryRefs"), "memoryRefs")?.unwrap_or_default();
        let narrower = match p.get("policy").and_then(Value::as_str).unwrap_or("same") {
            "same" => false,
            "narrower" => true,
            other => {
                return Err(RpcError::invalid_params(format!(
                    "policy must be same or narrower, not {other:?}"
                )));
            }
        };
        let _op = self.handoffs.ops.lock().await;
        let source = self.resolve(source_key);
        if let Some(existing) = self.handoffs.by_key(key) {
            let same_source = match &source {
                Ok(s) => s.id == existing.source.session_id,
                Err(_) => source_key == existing.source.session_id,
            };
            if !same_source {
                return Err(RpcError::invalid_params(format!(
                    "handoffKey {key:?} already names a handoff from another session"
                )));
            }
            return Ok(self.handoff_view(&existing));
        }
        let source = source?;
        if source.turn().is_some()
            || source.queued() > 0
            || !source.pending_permissions().is_empty()
        {
            return Err(refuse(
                CONFLICT,
                "source_busy",
                format!(
                    "session {} has a turn running, prompts queued or a permission waiting",
                    source.meta().name
                ),
                None,
            ));
        }
        let sm = source.meta();
        let (profile, family, default_policy) = {
            let cfg = self.config.read().await;
            let resolved = cfg.resolve_harness(harness).map_err(RpcError::invalid_params)?;
            let family = cfg
                .harnesses
                .get(&resolved)
                .map(|h| crate::config::derive_family(&resolved, h))
                .unwrap_or_else(|| resolved.clone());
            (resolved, family, cfg.permission_policy)
        };
        let source_family = sm.family.clone().unwrap_or_else(|| sm.harness.clone());
        if profile == sm.harness || family == source_family {
            return Err(refuse(
                INVALID,
                "same_harness",
                format!("{harness} is the source session's own harness ({})", sm.harness),
                None,
            ));
        }
        let source_policy = self.policy_for(&source, default_policy);
        let policy = if narrower {
            narrower_policy(source_policy).ok_or_else(|| {
                refuse(
                    INVALID,
                    "policy_unmappable",
                    format!("no acpmux policy is narrower than {source_policy}"),
                    None,
                )
            })?
        } else {
            source_policy
        };
        let to_seq = sm.last_seq;
        let built = self.build_capsule(&sm, to_seq)?;
        let target = self
            .new_session(NewRequest {
                harness: Some(profile),
                cwd: sm.cwd.clone(),
                policy: Some(policy),
                ..Default::default()
            })
            .await?;
        let at = now();
        let record = Record {
            handoff_id: uuid::Uuid::now_v7().to_string(),
            handoff_key: key.to_owned(),
            state: State::Draft,
            revision: 1,
            source: Side::of(&sm),
            source_seq: to_seq,
            target: Side::of(&target.meta()),
            text: built.text,
            context: built.context,
            checkpoint: checkpoint.map(stamp),
            memory_refs,
            coverage: built.coverage,
            prompt_id: None,
            turn_id: None,
            created_at: at.clone(),
            updated_at: at,
            draft_keys: Vec::new(),
        };
        if let Err(e) = self.handoffs.put(&record) {
            let _ = self.kill(&target, true).await;
            return Err(e);
        }
        Ok(self.handoff_view(&record))
    }

    /// `_acpmux/handoff_get`: by `handoffId`, or the handoff a session is
    /// the target or (newest, not discarded) source of; `null` for others.
    pub fn handoff_get(&self, p: &Value) -> Result<Value, RpcError> {
        if let Some(id) = text_param(p, "handoffId") {
            return self
                .handoffs
                .get(id)
                .map(|r| self.handoff_view(&r))
                .ok_or_else(|| not_found(id));
        }
        let key = text_param(p, "sessionId")
            .ok_or_else(|| RpcError::invalid_params("handoffId or sessionId is required"))?;
        let id = self.resolve(key).map(|s| s.id.clone()).unwrap_or_else(|_| key.to_owned());
        Ok(self.handoffs.for_session(&id).map(|r| self.handoff_view(&r)).unwrap_or(Value::Null))
    }

    /// `_acpmux/handoff_draft`: write the reviewed capsule. A repeated
    /// `draftKey` answers with the record; a stale `revision` succeeds only
    /// when its content equals the current draft.
    pub async fn handoff_draft(&self, p: &Value) -> Result<Value, RpcError> {
        let id = required(p, "handoffId")?;
        let revision = revision(p)?;
        let draft_key = required(p, "draftKey")?;
        let edit = Edit::parse(p)?;
        if edit.text.is_none() {
            return Err(RpcError::invalid_params("capsule.text is required"));
        }
        let _op = self.handoffs.ops.lock().await;
        let mut r = self.handoffs.get(id).ok_or_else(|| not_found(id))?;
        if r.draft_keys.iter().any(|k| k == draft_key) {
            return Ok(self.handoff_view(&r));
        }
        self.handoff_expect_draft(&r)?;
        let changed = edit.differs(&r);
        if changed && revision != r.revision {
            return Err(self.handoff_stale(&r, revision));
        }
        if changed {
            edit.apply(&mut r);
            r.revision += 1;
            r.updated_at = now();
        }
        r.remember_draft_key(draft_key);
        self.handoffs.put(&r)?;
        Ok(self.handoff_view(&r))
    }

    /// `_acpmux/handoff_start`: send the capsule to the target once, as
    /// `session/prompt` with `promptId` (default: the handoffId) and
    /// `resend`. A retry with the same `promptId` answers `already_started`
    /// from the record or the target's log and never sends twice.
    pub async fn handoff_start(self: &Arc<Self>, p: &Value) -> Result<Value, RpcError> {
        let id = required(p, "handoffId")?;
        let revision = revision(p)?;
        let edit = Edit::parse(p)?;
        let _op = self.handoffs.ops.lock().await;
        let mut r = self.handoffs.get(id).ok_or_else(|| not_found(id))?;
        let prompt_id = text_param(p, "promptId").unwrap_or(&r.handoff_id).to_owned();
        match r.state {
            State::Discarded => {
                return Err(refuse(
                    CONFLICT,
                    "discarded",
                    "the handoff was discarded",
                    Some(self.handoff_view(&r)),
                ));
            }
            State::Starting | State::Started => {
                if r.prompt_id.as_deref() != Some(prompt_id.as_str()) {
                    return Err(refuse(
                        CONFLICT,
                        "already_started",
                        format!(
                            "the handoff started with promptId {}",
                            r.prompt_id.as_deref().unwrap_or("?")
                        ),
                        Some(self.handoff_view(&r)),
                    ));
                }
                return self.handoff_deliver(r, true).await;
            }
            State::Draft => {}
        }
        let changed = edit.differs(&r);
        if changed && revision != r.revision {
            return Err(self.handoff_stale(&r, revision));
        }
        if changed {
            edit.apply(&mut r);
            r.revision += 1;
        }
        if r.checkpoint.is_none() {
            return Err(refuse(
                INVALID,
                "checkpoint_required",
                "start needs a checkpoint on the draft or in its params",
                None,
            ));
        }
        r.state = State::Starting;
        r.prompt_id = Some(prompt_id);
        r.updated_at = now();
        // Recorded before the send, so a lost reply or a restart is
        // reconciled by promptId instead of sent again.
        self.handoffs.put(&r)?;
        self.handoff_deliver(r, false).await
    }

    /// `_acpmux/handoff_discard`: close the never-prompted target. The
    /// source is untouched; discarding twice is fine.
    pub async fn handoff_discard(&self, p: &Value) -> Result<Value, RpcError> {
        let id = required(p, "handoffId")?;
        let _op = self.handoffs.ops.lock().await;
        let mut r = self.handoffs.get(id).ok_or_else(|| not_found(id))?;
        match r.state {
            State::Discarded => {}
            State::Starting | State::Started => {
                return Err(refuse(
                    CONFLICT,
                    "already_started",
                    "a started handoff cannot be discarded; its target has its first prompt",
                    Some(self.handoff_view(&r)),
                ));
            }
            State::Draft => {
                if let Ok(target) = self.resolve(&r.target.session_id) {
                    self.kill(&target, false).await?;
                }
                r.state = State::Discarded;
                r.updated_at = now();
                self.handoffs.put(&r)?;
            }
        }
        Ok(json!({"handoffId": r.handoff_id, "discarded": true}))
    }

    fn handoff_expect_draft(&self, r: &Record) -> Result<(), RpcError> {
        match r.state {
            State::Draft => Ok(()),
            State::Discarded => Err(refuse(
                CONFLICT,
                "discarded",
                "the handoff was discarded",
                Some(self.handoff_view(r)),
            )),
            State::Starting | State::Started => Err(refuse(
                CONFLICT,
                "not_draft",
                "the handoff has started; its capsule is fixed",
                Some(self.handoff_view(r)),
            )),
        }
    }

    fn handoff_stale(&self, r: &Record, revision: u64) -> RpcError {
        refuse(
            CONFLICT,
            "stale_revision",
            format!("revision {revision} is not the current revision {}", r.revision),
            Some(self.handoff_view(r)),
        )
    }

    /// Send the capsule (unless a retry finds it already in the target) and
    /// record the receipt.
    async fn handoff_deliver(
        self: &Arc<Self>,
        mut r: Record,
        retry: bool,
    ) -> Result<Value, RpcError> {
        let prompt_id = r.prompt_id.clone().unwrap_or_else(|| r.handoff_id.clone());
        let target = self.resolve(&r.target.session_id)?;
        let found = if retry {
            r.turn_id.clone().or_else(|| self.handoff_turn_for(&target, &prompt_id))
        } else {
            None
        };
        let (turn_id, outcome) = match found {
            Some(t) => (Some(t), "already_started"),
            None if retry && r.state == State::Started => (None, "already_started"),
            None => (self.handoff_send(&target, &r, &prompt_id).await?, "started"),
        };
        if !retry && std::env::var(DROP_START_REPLY_ENV).is_ok_and(|v| v == "1") {
            return Err(refuse(
                -32603,
                "uncertain_delivery",
                format!(
                    "{DROP_START_REPLY_ENV} dropped the reply to this start; retry with promptId {prompt_id}"
                ),
                Some(self.handoff_view(&r)),
            ));
        }
        r.state = State::Started;
        if turn_id.is_some() {
            r.turn_id = turn_id;
        }
        r.updated_at = now();
        self.handoffs.put(&r)?;
        Ok(json!({
            "handoffId": r.handoff_id,
            "targetSessionId": r.target.session_id,
            "promptId": prompt_id,
            "turnId": r.turn_id,
            "outcome": outcome,
        }))
    }

    /// Prompt the target and wait only until the prompt is recorded; the
    /// turn itself runs on. Returns the turn id when known.
    async fn handoff_send(
        self: &Arc<Self>,
        target: &Arc<Session>,
        r: &Record,
        prompt_id: &str,
    ) -> Result<Option<String>, RpcError> {
        let mut blocks = vec![json!({"type": "text", "text": r.text})];
        if let Some(note) = references(r) {
            blocks.push(json!({"type": "text", "text": note}));
        }
        let (tx, rx) = tokio::sync::oneshot::channel::<Value>();
        let opts = PromptOptions {
            prompt_id: Some(prompt_id.to_owned()),
            on_accepted: Some(Box::new(move |v: Value| {
                let _ = tx.send(v);
            })),
            resend: true,
        };
        let (hub, session) = (self.clone(), target.clone());
        let run =
            tokio::spawn(
                async move { hub.prompt_with(&session, blocks, "handoff", false, opts).await },
            );
        match rx.await {
            Ok(accepted) => Ok(accepted
                .get("turnId")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| self.handoff_turn_for(target, prompt_id))),
            // Refused before it was recorded: the prompt's own error.
            Err(_) => match run.await {
                Ok(Ok(v)) => {
                    Ok(v.pointer("/_meta/acpmux/turnId").and_then(Value::as_str).map(str::to_owned))
                }
                Ok(Err(e)) => Err(e),
                Err(e) => Err(RpcError::internal(format!("handoff delivery stopped: {e}"))),
            },
        }
    }

    /// The turn a prompt id started or queued in `session`: live state
    /// first, then the session's log (which outlives a restart).
    fn handoff_turn_for(&self, session: &Session, prompt_id: &str) -> Option<String> {
        if let Some(t) = session.turn().filter(|t| t.prompt_id == prompt_id) {
            return Some(t.turn_id);
        }
        if let Some(q) = session.queue().into_iter().find(|q| q.prompt_id == prompt_id) {
            return Some(q.turn_id);
        }
        let mut found = None;
        let _ = self.store.scan(&session.id, 0, &mut |rec: EventRecord| {
            if matches!(rec.kind.as_str(), "user_message" | "queued")
                && rec.msg.get("promptId").and_then(Value::as_str) == Some(prompt_id)
            {
                found = rec.msg.get("turnId").and_then(Value::as_str).map(str::to_owned);
                return false;
            }
            true
        });
        found
    }
}
