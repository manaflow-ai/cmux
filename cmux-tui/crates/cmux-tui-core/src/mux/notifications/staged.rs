//! A durable notification in 2 steps: staged, then committed.
//!
//! Staged: its effect receipt is `executing` in the registry (one commit,
//! durable before the post) and the notification is posted in memory. The
//! outcome commit comes next: alone (`commit_staged_notification`), or in the
//! transaction of the agent report of the same hook (`agent_reports.rs`), so
//! a hook that notifies and reports makes one commit for both.
//!
//! A daemon that stops between the 2 steps finds the receipt `executing` at
//! its next start and makes it `indeterminate`: the same key then posts
//! nothing, and its caller goes on without the notification.

use super::*;

const OPERATION: &str = "notification.create";

/// A notification whose effect receipt is `executing` and which is posted in
/// memory. Its outcome is not committed yet.
pub(in crate::mux) struct StagedNotification {
    pub(in crate::mux) actor: Actor,
    idempotency_key: String,
    fingerprint: Value,
    outcome: ResourceEffectOutcome,
    deltas: Value,
    pub(in crate::mux) notification: ResourceNotification,
    pub(in crate::mux) numeric_id: u64,
}

impl StagedNotification {
    /// The outcome intent for the transaction of the agent report of the
    /// same hook. `write`: the rows of its feed post (`decide_feed_post`).
    pub(in crate::mux) fn outcome_intent(
        &self,
        registry: &WorkspaceRegistry,
        write: crate::workspace_registry::OwnedTransactionWrite,
    ) -> anyhow::Result<crate::workspace_registry::EffectCommitIntent> {
        let (intent, _) = registry.prepare_effect_outcome_intent_with(
            &self.idempotency_key,
            OPERATION,
            &self.fingerprint,
            &self.outcome,
            Some(&self.deltas),
            write,
        )?;
        Ok(intent)
    }

    /// The agent session of the notification's terminal in `records`, for
    /// the `notification` event of an agent's notification.
    pub(in crate::mux) fn agent_session(
        &self,
        records: &HashMap<TerminalPublicId, TerminalAgentRecord>,
    ) -> Option<String> {
        let terminal = self.notification.terminal_id.as_ref()?;
        if self.notification.source != NotificationSource::Agent {
            return None;
        }
        records.get(terminal)?.agent_session_id.clone()
    }
}

impl Mux {
    /// Stage a durable notification under a caller-owned idempotency key
    /// (`create_durable_notification`). `None`: the key committed before, so
    /// a replay posts nothing; or its outcome is not known after a crash, and
    /// the caller goes on without the notification.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn stage_durable_notification(
        &self,
        actor: &Actor,
        idempotency_key: &str,
        title: String,
        subtitle: Option<String>,
        body: String,
        level: NotificationLevel,
        surface: Option<SurfaceId>,
        source: NotificationSource,
        desktop: bool,
    ) -> anyhow::Result<Option<StagedNotification>> {
        let terminal_id = surface.and_then(|surface| {
            let state = self.state.lock().unwrap();
            state
                .surfaces
                .get(&surface)
                .or_else(|| state.terminal_runtime_by_id(surface))
                .and_then(|surface| surface.terminal_public_id().cloned())
        });
        // The fingerprint names the subtitle only when one was given, so a key
        // minted before subtitles existed (an agent-hook retry across an
        // upgrade) still matches its stored receipt.
        let mut fingerprint = serde_json::json!({
            "operation": OPERATION,
            "origin": "durable-notification",
            "title": title,
            "body": body,
            "level": level.as_str(),
            "terminal_id": terminal_id,
        });
        if let Some(subtitle) = &subtitle {
            fingerprint.set("subtitle", serde_json::json!(subtitle));
        }
        let (preparation, executing) = match self.lookup_resource_effect(
            idempotency_key,
            OPERATION,
            &fingerprint,
        )? {
            Some(preparation) => (preparation, false),
            None => {
                let intent = serde_json::json!({
                    "notification_id": NotificationPublicId::random().map_err(anyhow::Error::new)?,
                    "title": title,
                    "subtitle": subtitle,
                    "body": body,
                    "level": level.as_str(),
                    "terminal_id": terminal_id,
                    "created_at_ms": now_ms(),
                    "source": source.as_str(),
                    "desktop": desktop,
                });
                // A new intent is recorded as `executing` in the same commit:
                // it is durable before the post, in one commit and not in 2.
                self.prepare_resource_effect_executing(
                    &WorkspaceMutation::new(idempotency_key, "resource-api", actor.clone())?,
                    OPERATION,
                    &fingerprint,
                    &intent,
                    None,
                )?
            }
        };
        let intent = match preparation {
            ResourceEffectPreparation::Committed { outcome, .. } => {
                return match outcome {
                    ResourceEffectOutcome::Success(_) => Ok(None),
                    ResourceEffectOutcome::Failure(error) => Err(anyhow::Error::new(error)),
                };
            }
            ResourceEffectPreparation::Indeterminate => {
                // The post may or may not have happened before a crash. A
                // notification is advisory, so the caller proceeds without it
                // rather than retrying the same key forever; the agent-hook
                // fold in particular must still commit its report and fence.
                self.report_internal_diagnostic("notification effect indeterminate, skipped");
                return Ok(None);
            }
            ResourceEffectPreparation::Execute { intent, .. } if executing => intent,
            // A receipt that an earlier daemon left `pending`.
            ResourceEffectPreparation::Execute { .. } => {
                self.mark_resource_effect_executing(idempotency_key, OPERATION, &fingerprint)?
            }
        };
        let notification_id: NotificationPublicId =
            serde_json::from_value(intent["notification_id"].clone())
                .context("stored notification intent has an invalid identity")?;
        let created_at_ms = intent
            .get("created_at_ms")
            .and_then(Value::as_u64)
            .context("stored notification intent has an invalid timestamp")?;
        // An intent prepared by a daemon without sources has none; the
        // producer retrying it now names it.
        let source = intent
            .get("source")
            .and_then(Value::as_str)
            .and_then(NotificationSource::parse)
            .unwrap_or(source);
        // An intent from before `desktop` existed was a desktop notification.
        let desktop = intent.get("desktop").and_then(Value::as_bool).unwrap_or(true);
        let numeric_id = self.post_resource_notification(
            notification_id.clone(),
            title.clone(),
            subtitle.clone(),
            body.clone(),
            level,
            surface,
            terminal_id.clone(),
            None,
            created_at_ms,
            source,
            desktop,
            false,
        );
        let session_id = self.workspace_registry.lock().unwrap().session_id().clone();
        let notification = ResourceNotification {
            id: notification_id.clone(),
            title,
            subtitle,
            body,
            level,
            terminal_id,
            workspace_id: None,
            created_at_ms,
            source,
            surface,
            desktop,
            reply: false,
        };
        let value = self.created_notification_value(&notification, &session_id);
        let outcome = ResourceEffectOutcome::Success(value.clone());
        let deltas = serde_json::json!([{
            "kind":"upsert",
            "sequence":0,
            "resource":"notification",
            "id":notification_id,
            "value":value,
        }]);
        Ok(Some(StagedNotification {
            actor: actor.clone(),
            idempotency_key: idempotency_key.to_owned(),
            fingerprint,
            outcome,
            deltas,
            notification,
            numeric_id,
        }))
    }

    /// Commit the outcome of a staged notification alone, with its local feed
    /// post. Returns the session-local legacy notification id.
    pub(super) fn commit_staged_notification(
        &self,
        staged: StagedNotification,
    ) -> anyhow::Result<u64> {
        let key = &staged.idempotency_key;
        if let Err(error) = self.commit_notification_effect(
            &staged.actor,
            key,
            &staged.fingerprint,
            &staged.outcome,
            &staged.deltas,
            &staged.notification,
            staged.numeric_id,
        ) {
            self.report_resource_effect_indeterminate(
                key,
                OPERATION,
                &format!("the outcome commit failed: {error:#}"),
            );
            let _ = self.mark_resource_effect_indeterminate(key);
            return Err(error.context("notification effect commit failed"));
        }
        self.prune_evicted_notification_reads();
        Ok(staged.numeric_id)
    }

    /// Stage the notification of the agent hook at journal `sequence`, if
    /// the hook has one (`notice`). Its key is derived from the sequence, so
    /// a retry of the hook replays the notification and posts nothing.
    pub(in crate::mux) fn stage_agent_hook_notification(
        &self,
        notice: Option<(String, String, NotificationLevel)>,
        surface: SurfaceId,
        sequence: u64,
    ) -> anyhow::Result<Option<StagedNotification>> {
        let Some((title, body, level)) = notice else { return Ok(None) };
        self.stage_durable_notification(
            &Actor::Daemon,
            &format!("agent-hook-notification-{sequence}"),
            title,
            None,
            body,
            level,
            Some(surface),
            NotificationSource::Agent,
            true,
        )
        .with_context(|| format!("agent hook notification for sequence {sequence}"))
    }

    /// Commit alone the staged notification of an agent hook, if one is
    /// left: the hook reports nothing, or its agent report did not take the
    /// notification into its commit (the report refused, failed or
    /// replayed). The notification is then durable as it was when the two
    /// were 2 commits, and a retry of the hook replays it.
    pub(in crate::mux) fn commit_agent_hook_notification(
        &self,
        staged: Option<StagedNotification>,
        sequence: u64,
    ) -> anyhow::Result<()> {
        let Some(staged) = staged else { return Ok(()) };
        self.commit_staged_notification(staged)
            .map(drop)
            .with_context(|| format!("agent hook notification for sequence {sequence}"))
    }
}
