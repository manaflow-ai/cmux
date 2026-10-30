//! Notifications: per-surface unread markers, posting (CLI, terminal, resource), the durable notification ledger, reads, acks and clears.

use super::*;
use cmux_json::JsonSet as _;

impl Mux {
    pub fn surface_notification(&self, surface: SurfaceId) -> Option<SurfaceNotification> {
        let state = self.state.lock().unwrap();
        let terminal_id =
            match state.surfaces.get(&surface).or_else(|| state.terminal_runtime_by_id(surface)) {
                Some(runtime) => runtime.terminal_public_id().cloned(),
                // A terminal tab whose host still adopts: its content binding.
                None => match state.resource_indexes.content_ids.get(&surface) {
                    Some(ContentPublicId::Terminal(terminal_id)) => Some(terminal_id.clone()),
                    _ => None,
                },
            };
        drop(state);
        match terminal_id {
            Some(terminal_id) => {
                self.terminal_notifications.lock().unwrap().get(&terminal_id).copied()
            }
            None => self.placement_notifications.lock().unwrap().get(&surface).copied(),
        }
    }

    pub(crate) fn terminal_notification(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> Option<SurfaceNotification> {
        self.terminal_notifications.lock().unwrap().get(terminal_id).copied()
    }

    pub fn surface_notifications(&self) -> HashMap<SurfaceId, SurfaceNotification> {
        let state = self.state.lock().unwrap();
        self.surface_notifications_in_state(&state)
    }

    pub(super) fn surface_notifications_in_state(
        &self,
        state: &State,
    ) -> HashMap<SurfaceId, SurfaceNotification> {
        let placement_notifications = self.placement_notifications.lock().unwrap();
        let terminal_notifications = self.terminal_notifications.lock().unwrap();
        let mut result = HashMap::new();
        for (surface_id, surface) in &state.surfaces {
            let notification = match surface.terminal_public_id() {
                Some(terminal_id) => terminal_notifications.get(terminal_id),
                None => placement_notifications.get(surface_id),
            };
            if let Some(notification) = notification {
                result.insert(*surface_id, *notification);
            }
        }
        // A terminal tab with no runtime surface yet (its host still adopts
        // after a restart, 81577dcd4b3) keeps its terminal's marker through
        // the tab's content binding, which exists before the adoption: the
        // ring and the workspace's unread count never blink out.
        for (surface_id, content) in &state.resource_indexes.content_ids {
            if state.surfaces.contains_key(surface_id) {
                continue;
            }
            if let ContentPublicId::Terminal(terminal_id) = content
                && let Some(notification) = terminal_notifications.get(terminal_id)
            {
                result.insert(*surface_id, *notification);
            }
        }
        result
    }

    /// Post a notification from the legacy `notify` verb. This is the same
    /// durable path as `notification.create`, under a fresh key, so remote
    /// subscribers of the resource feed and a restarted daemon see it too.
    #[cfg(test)]
    pub(crate) fn post_notification(
        &self,
        title: String,
        body: String,
        level: NotificationLevel,
        surface: Option<SurfaceId>,
    ) -> anyhow::Result<u64> {
        self.post_notification_as(
            &Actor::Daemon,
            title,
            body,
            level,
            surface,
            NotificationSource::Cli,
        )
    }

    /// A fresh notification that `actor` posts, with an explicit source.
    pub fn post_notification_as(
        &self,
        actor: &Actor,
        title: String,
        body: String,
        level: NotificationLevel,
        surface: Option<SurfaceId>,
        source: NotificationSource,
    ) -> anyhow::Result<u64> {
        let key = format!("notify-{}", crate::workspace_registry::new_uuid_v4());
        self.create_durable_notification(actor, &key, title, None, body, level, surface, source)?
            .context("fresh notify key unexpectedly replayed")
    }

    /// Post what a program in `surface`'s terminal asked for with OSC 9,
    /// OSC 777 or OSC 99, or an OSC 7501 record's alert. Called by the terminal's output reader after it
    /// released the terminal lock; the reader already applied the rate limit.
    pub(crate) fn post_terminal_notifications(
        &self,
        surface: SurfaceId,
        notifications: Vec<crate::terminal_metadata::TerminalNotification>,
    ) {
        for notification in notifications {
            if self
                .post_notification_as(
                    &Actor::Daemon,
                    notification.title,
                    notification.body,
                    notification.level,
                    Some(surface),
                    NotificationSource::Terminal,
                )
                .is_err()
            {
                self.report_internal_diagnostic("terminal notification not posted");
            }
        }
    }

    /// A bell (BEL) in `surface`'s terminal marks its tab for attention like a
    /// notification (cx-on7iu, Lawrence 2026-10-14: a terminal bell must mark the
    /// sidebar row like a notification). It is a mark, not an alert: no desktop
    /// banner or sound (`desktop: false`), and none while the terminal still has
    /// an unread notification, so a program that rings in a loop marks its tab
    /// once and never pushes real notifications out of the ledger. The terminal's
    /// reader also posts at most one per cooldown (`PendingBells`).
    pub(crate) fn post_bell_notification(&self, surface: SurfaceId) {
        if self.surface_notification(surface).is_some_and(|marker| marker.unread) {
            return;
        }
        let key = format!("bell-{}", crate::workspace_registry::new_uuid_v4());
        if self
            .create_durable_notification_with(
                &Actor::Daemon,
                &key,
                "Bell".to_string(),
                None,
                String::new(),
                NotificationLevel::Info,
                Some(surface),
                NotificationSource::Terminal,
                false,
            )
            .is_err()
        {
            self.report_internal_diagnostic("bell notification not posted");
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn post_resource_notification(
        &self,
        public_id: NotificationPublicId,
        title: String,
        subtitle: Option<String>,
        body: String,
        level: NotificationLevel,
        surface: Option<SurfaceId>,
        terminal_id: Option<TerminalPublicId>,
        workspace_id: Option<WorkspacePublicId>,
        created_at_ms: u64,
        source: NotificationSource,
        desktop: bool,
        reply: bool,
    ) -> u64 {
        let id = self.next_notification_id();
        // Who holds the terminal now: a reply typed into it later must reach this same program.
        let poster = surface.and_then(|surface| self.surface(surface)).and_then(|surface| {
            let pid = surface.process_id()?;
            Some(NotificationPoster {
                pid: crate::platform::foreground_leader(pid)?,
                executable: crate::platform::foreground_process_name(pid)?,
            })
        });
        self.notification_posts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(public_id.clone(), NotificationPost { notification: id, poster });
        {
            const NOTIFICATION_LEDGER_CAPACITY: usize = 256;
            let mut ledger = self.notification_ledger.lock().unwrap();
            ledger.push_back(ResourceNotification {
                id: public_id,
                title,
                subtitle,
                body,
                level,
                terminal_id,
                workspace_id,
                created_at_ms,
                source,
                surface,
                desktop,
                reply,
            });
            let mut evicted = Vec::new();
            while ledger.len() > NOTIFICATION_LEDGER_CAPACITY {
                if let Some(old) = ledger.pop_front() {
                    evicted.push(old.id);
                }
            }
            if !evicted.is_empty() {
                let mut posts =
                    self.notification_posts.lock().unwrap_or_else(PoisonError::into_inner);
                for id in &evicted {
                    posts.remove(id);
                }
                drop(posts);
                let mut reads = self.notification_reads.lock().unwrap();
                for id in &evicted {
                    reads.remove(id);
                }
                self.notification_read_prunes.lock().unwrap().extend(evicted);
            }
        }
        // The ring and the `notification` event follow the commit
        // (`commit_notification_effect`), under the feed lock with the item.
        id
    }

    pub fn resource_notifications(&self, limit: usize) -> Vec<ResourceNotification> {
        let mut notifications = self
            .notification_ledger
            .lock()
            .unwrap()
            .iter()
            .rev()
            .take(limit.min(256))
            .cloned()
            .collect::<Vec<_>>();
        let state = self.state.lock().unwrap();
        for notification in &mut notifications {
            if let Some(terminal_id) = &notification.terminal_id {
                notification.surface = state
                    .placements_of_content(&ContentPublicId::Terminal(terminal_id.clone()))
                    .first()
                    .copied()
                    .or_else(|| state.terminal_catalog.get(terminal_id).map(|surface| surface.id));
            }
        }
        notifications
    }

    /// The event number and poster of a ledger row this run posted; `None`
    /// for a row restored from disk or evicted.
    pub fn notification_post(
        &self,
        notification: &NotificationPublicId,
    ) -> Option<NotificationPost> {
        self.notification_posts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(notification)
            .cloned()
    }

    /// Client ids that acknowledged `notification`, sorted and unique.
    pub fn notification_read_by(&self, notification: &NotificationPublicId) -> Vec<String> {
        self.notification_reads
            .lock()
            .unwrap()
            .get(notification)
            .map(|clients| clients.iter().cloned().collect())
            .unwrap_or_default()
    }

    /// The public snapshot row for one ledger entry. Every producer of a
    /// `notification` resource value goes through here so create results,
    /// acknowledgement deltas, and session snapshots cannot drift.
    pub(crate) fn notification_snapshot_value(
        &self,
        notification: &ResourceNotification,
        session_id: &SessionPublicId,
        read_by: &[String],
    ) -> Value {
        let unread = notification
            .terminal_id
            .as_ref()
            .and_then(|terminal_id| self.terminal_notification(terminal_id))
            .is_some_and(|marker| marker.unread);
        let mut value = serde_json::json!({
            "id": notification.id,
            "session_id": session_id,
            "title": notification.title,
            "body": notification.body,
            "level": notification.level.as_str(),
            "created_at_ms": notification.created_at_ms.to_string(),
            "unread": unread,
            "read_by": read_by,
        });
        if let Some(terminal_id) = &notification.terminal_id {
            value.set("terminal_id", serde_json::json!(terminal_id));
        }
        if let Some(subtitle) = &notification.subtitle {
            value.set("subtitle", serde_json::json!(subtitle));
        }
        // Stored under `extra`, which every registry schema already accepts,
        // so a downgraded daemon still opens the receipt.
        value.set("extra", serde_json::json!({"source": notification.source.as_str()}));
        if let Some(workspace) = &notification.workspace_id {
            value.set_path(&["extra", "workspace_id"], serde_json::json!(workspace));
        }
        value
    }

    /// The snapshot row of a notification being created. Its ring goes up
    /// in the commit (`commit_notification_effect`), after this value is
    /// built, so a terminal's new notification is unread here explicitly.
    pub(crate) fn created_notification_value(
        &self,
        notification: &ResourceNotification,
        session_id: &SessionPublicId,
    ) -> Value {
        let mut value = self.notification_snapshot_value(notification, session_id, &[]);
        value.set("unread", Value::Bool(notification.terminal_id.is_some()));
        // A non-terminal tab (an agent chat) is named by its content, so a
        // restart finds the tab again to dedupe and acknowledge against.
        if notification.terminal_id.is_none()
            && let Some(surface) = notification.surface
            && let Some(ContentPublicId::Browser(browser)) = self
                .state
                .lock()
                .unwrap()
                .surfaces
                .get(&surface)
                .and_then(|surface| surface.resource_identity())
                .map(|identity| identity.content_id.clone())
        {
            value.set_path(&["extra", "browser_id"], serde_json::json!(browser));
        }
        value
    }

    /// Post a notification through the durable `notification.create` effect
    /// path under a caller-owned idempotency key. Replaying the same key
    /// returns `None` without posting again, so journal-driven producers
    /// (agent hooks) and the legacy `notify` verb share one durable ledger
    /// with the resource API and survive a daemon restart. A fresh post
    /// returns the session-local legacy notification id.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn create_durable_notification(
        &self,
        actor: &Actor,
        idempotency_key: &str,
        title: String,
        subtitle: Option<String>,
        body: String,
        level: NotificationLevel,
        surface: Option<SurfaceId>,
        source: NotificationSource,
    ) -> anyhow::Result<Option<u64>> {
        self.create_durable_notification_with(
            actor,
            idempotency_key,
            title,
            subtitle,
            body,
            level,
            surface,
            source,
            true,
        )
    }

    /// `create_durable_notification` with `desktop`: false records the
    /// notification and its unread mark with no desktop banner (a bell).
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn create_durable_notification_with(
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
    ) -> anyhow::Result<Option<u64>> {
        const OPERATION: &str = "notification.create";
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
        let committed = |outcome: ResourceEffectOutcome| match outcome {
            ResourceEffectOutcome::Success(_) => Ok(None),
            ResourceEffectOutcome::Failure(error) => Err(anyhow::Error::new(error)),
        };
        let preparation = match self.lookup_resource_effect(
            idempotency_key,
            OPERATION,
            &fingerprint,
        )? {
            Some(preparation) => preparation,
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
                self.prepare_resource_effect(
                    &WorkspaceMutation::new(idempotency_key, "resource-api", actor.clone())?,
                    OPERATION,
                    &fingerprint,
                    &intent,
                    None,
                    None,
                )?
            }
        };
        let intent = match preparation {
            ResourceEffectPreparation::Committed { outcome, .. } => {
                return committed(outcome);
            }
            ResourceEffectPreparation::Indeterminate => {
                // The post may or may not have happened before a crash. A
                // notification is advisory, so the caller proceeds without it
                // rather than retrying the same key forever; the agent-hook
                // fold in particular must still commit its report and fence.
                self.report_internal_diagnostic("notification effect indeterminate, skipped");
                return Ok(None);
            }
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
        if let Err(error) = self.commit_notification_effect(
            actor,
            idempotency_key,
            &fingerprint,
            &outcome,
            &deltas,
            &notification,
            numeric_id,
        ) {
            let _ = self.mark_resource_effect_indeterminate(idempotency_key);
            return Err(error.context("notification effect commit failed"));
        }
        self.prune_evicted_notification_reads();
        Ok(Some(numeric_id))
    }

    /// Delete durable read marks for evicted notifications that the committed
    /// receipts no longer retain. Called after a notification create commits;
    /// ids still retained durably stay queued for a later create.
    pub(crate) fn prune_evicted_notification_reads(&self) {
        let candidates = std::mem::take(&mut *self.notification_read_prunes.lock().unwrap());
        if candidates.is_empty() {
            return;
        }
        let remaining =
            match self.workspace_registry.lock().unwrap().prune_notification_reads(&candidates) {
                Ok(remaining) => remaining,
                Err(_) => {
                    self.report_internal_diagnostic("notification read-mark prune deferred");
                    candidates
                }
            };
        if !remaining.is_empty() {
            self.notification_read_prunes.lock().unwrap().extend(remaining);
        }
    }

    /// Record that `client_id` read `notifications`. Unknown ids are reported,
    /// not rejected: a bounded ledger may have evicted them, and an
    /// acknowledgement of something already gone is complete by definition.
    /// The refreshed rows are published as one resource revision so every
    /// subscribed client converges on the same `read_by` sets.
    pub(crate) fn ack_notifications(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        client_id: &str,
        notifications: &[NotificationPublicId],
    ) -> anyhow::Result<ResourcePatchCommit> {
        const OPERATION: &str = "notification.ack";
        validate_client_id(client_id)?;
        let fingerprint = serde_json::json!({
            "operation": OPERATION,
            "client_id": client_id,
            "notifications": notifications,
        });
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(replay) = registry.replay_resource_patch(mutation, OPERATION, &fingerprint)? {
            return Ok(replay);
        }
        let session_id = registry.session_id().clone();
        let mut acknowledged: Vec<NotificationPublicId> = Vec::new();
        let mut unknown: Vec<NotificationPublicId> = Vec::new();
        let mut deltas = Vec::new();
        {
            let ledger = self.notification_ledger.lock().unwrap();
            let reads = self.notification_reads.lock().unwrap();
            for id in notifications {
                if acknowledged.contains(id) || unknown.contains(id) {
                    continue;
                }
                match ledger.iter().find(|entry| &entry.id == id) {
                    Some(entry) => {
                        let mut read_by = reads.get(id).cloned().unwrap_or_default();
                        read_by.insert(client_id.to_string());
                        let read_by = read_by.into_iter().collect::<Vec<_>>();
                        let value = self.notification_snapshot_value(entry, &session_id, &read_by);
                        deltas.push(serde_json::json!({
                            "kind":"upsert",
                            "sequence":0,
                            "resource":"notification",
                            "id":id,
                            "value":value,
                        }));
                        acknowledged.push(id.clone());
                    }
                    None => unknown.push(id.clone()),
                }
            }
        }
        let result = serde_json::json!({
            "client_id": client_id,
            "acknowledged": acknowledged,
            "unknown": unknown,
        });
        let commit = registry.commit_notification_ack(
            mutation,
            &fingerprint,
            expected_revision,
            client_id,
            &acknowledged,
            now_ms(),
            &result,
            &Value::Array(deltas),
        )?;
        if !commit.replayed {
            {
                let mut reads = self.notification_reads.lock().unwrap();
                for id in &acknowledged {
                    reads.entry(id.clone()).or_default().insert(client_id.to_string());
                }
            }
            self.state.lock().unwrap().resource_revision = commit.revision;
        }
        drop(registry);
        if !commit.replayed {
            self.publish_resource_event();
        }
        Ok(commit)
    }

    /// Remove retained notifications, for one terminal or the whole session.
    /// This is the source-of-truth form of a local `cmux notify --clear`: the
    /// rows leave the ledger, their durable receipts are masked by a clear
    /// record, every client receives a delete delta, and the console marker
    /// for the terminal is dropped.
    /// `clear_notifications_in` for one terminal or the session (tests).
    #[cfg(test)]
    pub(crate) fn clear_notifications(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        terminal_id: Option<&TerminalPublicId>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let scope = match terminal_id {
            Some(terminal) => NotificationClearScope::Terminal(terminal),
            None => NotificationClearScope::Session,
        };
        self.clear_notifications_in(mutation, expected_revision, scope)
    }

    /// `clear_notifications` for one terminal, one workspace (its own rows
    /// and those of every terminal and tab it shows), or the whole session.
    /// A workspace that is not in this session is an error.
    pub(crate) fn clear_notifications_in(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        scope: NotificationClearScope<'_>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let members = match scope {
            NotificationClearScope::Workspace(workspace) => Some(
                self.workspace_notification_members(workspace)
                    .with_context(|| format!("unknown workspace {}", workspace.as_str()))?,
            ),
            _ => None,
        };
        let cleared_scope = ClearedScope { scope, members: members.as_ref() };
        // The clear reads the cleared scope's local items (every item for a
        // session-wide clear) in its transaction, and drops the rings, under
        // the feed lock (mux/feed_local.rs).
        let mut committed = None;
        let cleared = |item: &cmux_feed_core::Item| cleared_scope.covers_item(item);
        let wrote = self.read_feed_items_in(cleared, |extra, feed| {
            let commit = self.apply_notification_clear(
                mutation,
                expected_revision,
                &cleared_scope,
                extra,
                feed,
            )?;
            let applied = !commit.replayed;
            committed = Some(commit);
            Ok(applied)
        })?;
        let commit = committed.context("notification clear did not run")?;
        if !commit.replayed {
            self.emit(MuxEvent::TreeChanged);
            self.publish_resource_event();
        }
        if wrote {
            self.publish_journal_event();
        }
        Ok(commit)
    }

    /// The `notification.clear` commit and its in-memory side; the caller
    /// holds the feed lock. `feed` is the feed after the clear's reads: a
    /// ring stays while an item it follows stays unread (moving, or owned
    /// elsewhere), as the tab ack keeps it.
    fn apply_notification_clear(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        cleared_scope: &ClearedScope<'_>,
        extra: Option<crate::workspace_registry::RegistryTransactionWrite<'_>>,
        feed: &cmux_feed_core::Feed,
    ) -> anyhow::Result<ResourcePatchCommit> {
        const OPERATION: &str = "notification.clear";
        let terminal_id = match cleared_scope.scope {
            NotificationClearScope::Terminal(terminal) => Some(terminal),
            _ => None,
        };
        // A terminal or session clear keeps the fingerprint it always had, so
        // a retried key from an older daemon still replays.
        let mut fingerprint = serde_json::json!({
            "operation": OPERATION,
            "terminal_id": terminal_id,
        });
        if let NotificationClearScope::Workspace(workspace) = cleared_scope.scope {
            fingerprint.set("workspace_id", serde_json::json!(workspace));
        }
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(replay) = registry.replay_resource_patch(mutation, OPERATION, &fingerprint)? {
            return Ok(replay);
        }
        let candidates: Vec<NotificationPublicId> = {
            let ledger = self.notification_ledger.lock().unwrap();
            ledger
                .iter()
                .filter(|entry| cleared_scope.covers_entry(entry))
                .map(|entry| entry.id.clone())
                .collect()
        };
        // Only durably committed rows are cleared. A row whose create receipt
        // is still in flight stays, so the clear cannot mask a receipt that
        // commits after it (the registry lock held here serializes the two).
        let cleared = registry.committed_notification_ids(&candidates)?;
        let deltas = cleared
            .iter()
            .map(|id| {
                serde_json::json!({
                    "kind":"delete",
                    "sequence":0,
                    "resource":"notification",
                    "id":id,
                })
            })
            .collect::<Vec<_>>();
        let result = serde_json::json!({ "cleared": cleared });
        let commit = registry.commit_notification_clear(
            mutation,
            &fingerprint,
            expected_revision,
            &cleared,
            &result,
            &Value::Array(deltas),
            extra,
        )?;
        if !commit.replayed {
            {
                let mut ledger = self.notification_ledger.lock().unwrap();
                ledger.retain(|entry| !cleared.contains(&entry.id));
            }
            {
                let mut reads = self.notification_reads.lock().unwrap();
                for id in &cleared {
                    reads.remove(id);
                }
            }
            let unread = feed.items().iter().filter(|item| item.is_unread()).collect::<Vec<_>>();
            let terminal_unread = |terminal: &TerminalPublicId| {
                unread
                    .iter()
                    .any(|item| item.context.terminal.as_deref() == Some(terminal.as_str()))
            };
            let tab_unread = |tabs: &HashMap<SurfaceId, TabPublicId>, surface: &SurfaceId| {
                tabs.get(surface).is_some_and(|tab| {
                    unread.iter().any(|item| {
                        item.context.terminal.is_none()
                            && item.context.tab.as_deref() == Some(tab.as_str())
                    })
                })
            };
            match (cleared_scope.scope, cleared_scope.members) {
                (NotificationClearScope::Terminal(terminal_id), _)
                    if !terminal_unread(terminal_id) =>
                {
                    self.terminal_notifications.lock().unwrap().remove(terminal_id);
                }
                (NotificationClearScope::Terminal(_), _) => {}
                (NotificationClearScope::Workspace(_), Some(members)) => {
                    self.terminal_notifications.lock().unwrap().retain(|terminal, _| {
                        !members.terminals.contains(terminal) || terminal_unread(terminal)
                    });
                    self.placement_notifications.lock().unwrap().retain(|surface, _| {
                        !members.surfaces.contains(surface) || tab_unread(&members.tabs, surface)
                    });
                }
                (NotificationClearScope::Workspace(_), None) => {}
                (NotificationClearScope::Session, _) => {
                    let tabs = self.with_state(|state| state.resource_indexes.tab_ids.clone());
                    self.terminal_notifications.lock().unwrap().retain(|t, _| terminal_unread(t));
                    self.placement_notifications
                        .lock()
                        .unwrap()
                        .retain(|surface, _| tab_unread(&tabs, surface));
                }
            }
            self.state.lock().unwrap().resource_revision = commit.revision;
        }
        drop(registry);
        Ok(commit)
    }
}

/// What a `notification.clear` removes.
#[derive(Debug, Clone, Copy)]
pub(crate) enum NotificationClearScope<'a> {
    /// Every retained notification of the session.
    Session,
    /// One terminal's notifications.
    Terminal(&'a TerminalPublicId),
    /// One workspace's: its terminal-less rows (`notify --workspace`) and
    /// those of every terminal and tab it shows.
    Workspace(&'a WorkspacePublicId),
}

/// The terminals, views and tabs one workspace shows, read before the clear
/// takes the feed and registry locks.
#[derive(Debug, Default)]
pub(crate) struct WorkspaceNotificationMembers {
    terminals: HashSet<TerminalPublicId>,
    surfaces: HashSet<SurfaceId>,
    tabs: HashMap<SurfaceId, TabPublicId>,
}

/// A clear's scope with the members a workspace scope resolved to.
struct ClearedScope<'a> {
    scope: NotificationClearScope<'a>,
    members: Option<&'a WorkspaceNotificationMembers>,
}

impl ClearedScope<'_> {
    fn covers_entry(&self, entry: &ResourceNotification) -> bool {
        match self.scope {
            NotificationClearScope::Session => true,
            NotificationClearScope::Terminal(terminal) => {
                entry.terminal_id.as_ref() == Some(terminal)
            }
            NotificationClearScope::Workspace(workspace) => {
                entry.workspace_id.as_ref() == Some(workspace)
                    || entry.terminal_id.as_ref().is_some_and(|terminal| {
                        self.members.is_some_and(|members| members.terminals.contains(terminal))
                    })
                    || entry.surface.is_some_and(|surface| {
                        self.members.is_some_and(|members| members.surfaces.contains(&surface))
                    })
            }
        }
    }

    fn covers_item(&self, item: &cmux_feed_core::Item) -> bool {
        let terminal = item.context.terminal.as_deref();
        match self.scope {
            NotificationClearScope::Session => true,
            NotificationClearScope::Terminal(wanted) => terminal == Some(wanted.as_str()),
            NotificationClearScope::Workspace(_) => self.members.is_some_and(|members| {
                terminal.is_some_and(|terminal| {
                    members.terminals.iter().any(|known| known.as_str() == terminal)
                }) || item
                    .context
                    .tab
                    .as_deref()
                    .is_some_and(|tab| members.tabs.values().any(|known| known.as_str() == tab))
            }),
        }
    }
}

impl Mux {
    /// The terminals, views and tabs `workspace` shows; None when it is not
    /// a workspace of this session.
    pub(crate) fn workspace_notification_members(
        &self,
        workspace: &WorkspacePublicId,
    ) -> Option<WorkspaceNotificationMembers> {
        self.with_state(|state| {
            let id =
                state.workspaces.iter().find(|candidate| candidate.public_id == *workspace)?.id;
            let mut members = WorkspaceNotificationMembers::default();
            for (surface_id, surface) in &state.surfaces {
                if Self::workspace_for_surface_in_state(state, *surface_id) != Some(id) {
                    continue;
                }
                members.surfaces.insert(*surface_id);
                if let Some(terminal) = surface.terminal_public_id() {
                    members.terminals.insert(terminal.clone());
                }
                if let Some(tab) = state.resource_indexes.tab_ids.get(surface_id) {
                    members.tabs.insert(*surface_id, tab.clone());
                }
            }
            Some(members)
        })
    }
}
