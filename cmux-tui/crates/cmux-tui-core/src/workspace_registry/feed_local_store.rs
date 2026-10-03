//! Durable items of the daemon's local feed owner (`feed-local-owner-v1`,
//! plans/cmux-next/feed.md section 9.1).
//!
//! `feed_local_items` holds one row per item: the indexed columns the store
//! filters on plus the full item as JSON. The table is additive and has no
//! foreign key, so creating it needs no schema version bump and an older
//! binary that opens the registry ignores it.
//!
//! Every write lands in the caller's transaction: a notification's local
//! `feed.post` commits with its `notification.create` receipt, and an
//! `ack-tab-notifications` read commits with the persisted ack.
//!
//! On first open the 256-entry notification ledger migrates into items (B4):
//! an entry becomes READ when any client's `read_by` mark or a persisted ack
//! exists. The dedupe key `notify:<daemon session>:<notification id>` and the
//! meta marker [`FEED_LOCAL_MIGRATION_META_KEY`] make the migration
//! idempotent.

use cmux_feed_core::{Changes, Context as FeedContext, Feed, Item, Notice, PostOutcome};
use rusqlite::{Transaction, params};
use serde_json::json;

use super::*;
use crate::resource::NotificationPublicId;

/// Meta key set once the notification ledger migrated into local items.
pub(crate) const FEED_LOCAL_MIGRATION_META_KEY: &str = "feed_local_ledger_migrated_v1";

pub(super) fn create_feed_local_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS feed_local_items (
           item_id TEXT PRIMARY KEY NOT NULL,
           dedupe_key TEXT NOT NULL UNIQUE,
           state TEXT NOT NULL,
           terminal_id TEXT,
           created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
           item_json TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS feed_local_items_state ON feed_local_items(state);",
    )?;
    Ok(())
}

/// Write one op's changed rows in the caller's transaction.
pub(crate) fn write_feed_local_changes(
    transaction: &Transaction<'_>,
    changes: &Changes,
) -> anyhow::Result<()> {
    for item in &changes.upserts {
        transaction.execute(
            "INSERT INTO feed_local_items(
               item_id, dedupe_key, state, terminal_id, created_at_ms, item_json)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(item_id) DO UPDATE SET
               state = excluded.state,
               terminal_id = excluded.terminal_id,
               item_json = excluded.item_json",
            params![
                item.id,
                item.dedupe_key,
                item.state.as_str(),
                item.context.terminal,
                i64::try_from(item.created_at_ms)?,
                serde_json::to_string(item)?,
            ],
        )?;
    }
    for id in &changes.removed {
        transaction.execute("DELETE FROM feed_local_items WHERE item_id = ?1", [id])?;
    }
    Ok(())
}

/// The local item id for the notification that creates it: the same hex as
/// the notification's public id, so the migration and a live post agree.
pub(crate) fn feed_item_id(notification: &NotificationPublicId) -> String {
    let id = notification.as_str();
    format!("feeditem_{}", id.strip_prefix("notification_").unwrap_or(id))
}

/// `notify:<daemon session>:<public notification id>` (section 9.1 item 3).
pub(crate) fn notify_dedupe_key(
    session: &SessionPublicId,
    notification: &NotificationPublicId,
) -> String {
    format!("notify:{}:{}", session.as_str(), notification.as_str())
}

impl WorkspaceRegistry {
    /// Every stored local item, oldest first.
    pub(crate) fn feed_local_items(&self) -> anyhow::Result<Vec<Item>> {
        let mut statement = self.connection.prepare(
            "SELECT item_json FROM feed_local_items ORDER BY created_at_ms ASC, item_id ASC",
        )?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        let mut items = Vec::new();
        for row in rows {
            // A row this binary cannot decode (a state a newer daemon wrote)
            // stays on disk untouched; it must not stop the daemon opening.
            match serde_json::from_str::<Item>(&row?) {
                Ok(item) => items.push(item),
                Err(error) => eprintln!("cmux-tui: skipping a local feed item: {error}"),
            }
        }
        Ok(items)
    }

    /// Migrate the ledger once, then load the local owner's items.
    pub(crate) fn open_feed_local(&mut self) -> anyhow::Result<Feed> {
        self.migrate_feed_local_from_ledger()?;
        Ok(Feed::from_items(self.feed_local_items()?))
    }

    /// B4: each retained ledger entry becomes a local item, READ iff a client
    /// read it (`read_by`) or an ack was persisted. Returns how many items it
    /// added; a second run adds none (meta marker plus dedupe keys).
    pub(crate) fn migrate_feed_local_from_ledger(&mut self) -> anyhow::Result<usize> {
        if meta_value(&self.connection, FEED_LOCAL_MIGRATION_META_KEY)?.is_some() {
            return Ok(0);
        }
        let live = self.live_terminal_public_ids()?;
        let entries = self.durable_notifications(&live)?;
        let acked = self.acked_notification_ids()?;
        let mut feed = Feed::from_items(self.feed_local_items()?);
        let session = self.session_id().clone();
        let mut changes = Changes::default();
        for entry in entries {
            let notice = Notice {
                id: feed_item_id(&entry.id),
                dedupe_key: notify_dedupe_key(&session, &entry.id),
                title: entry.title,
                body: entry.body,
                level: entry.level,
                source: entry.source.as_str().to_string(),
                context: FeedContext {
                    terminal: entry.terminal_id.map(|terminal| terminal.as_str().to_string()),
                    ..FeedContext::default()
                },
                actor: None,
                at_ms: entry.created_at_ms,
                read: !entry.read_by.is_empty() || acked.contains(entry.id.as_str()),
                coalesce: false,
            };
            // An entry the reducer refuses (an id already taken under another
            // key) stays out; the ledger keeps it until it is evicted.
            if let Ok((PostOutcome::Created(_), posted)) = feed.post(notice) {
                changes.upserts.extend(posted.upserts);
            }
        }
        // Pruning is the reducer's job on the next live op; the migration
        // keeps every retained entry so nothing read-relevant is lost.
        let added = changes.upserts.len();
        let tx = self.connection.transaction()?;
        write_feed_local_changes(&tx, &changes)?;
        tx.execute(
            "INSERT OR REPLACE INTO meta(key, value) VALUES(?1, ?2)",
            params![FEED_LOCAL_MIGRATION_META_KEY, added.to_string()],
        )?;
        tx.commit()?;
        Ok(added)
    }

    /// Drop every local item and the migration marker, as a registry written
    /// by a daemon without the local owner.
    #[cfg(test)]
    pub(crate) fn forget_feed_local_for_test(&mut self) -> anyhow::Result<()> {
        self.connection.execute("DELETE FROM feed_local_items", [])?;
        self.forget_feed_local_marker_for_test()
    }

    /// Drop the items of `ids` only, as notifications an older daemon wrote.
    #[cfg(test)]
    pub(crate) fn forget_feed_local_items_for_test(
        &mut self,
        ids: &[String],
    ) -> anyhow::Result<()> {
        for id in ids {
            self.connection.execute("DELETE FROM feed_local_items WHERE item_id = ?1", [id])?;
        }
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn forget_feed_local_marker_for_test(&mut self) -> anyhow::Result<()> {
        self.connection
            .execute("DELETE FROM meta WHERE key = ?1", [FEED_LOCAL_MIGRATION_META_KEY])?;
        Ok(())
    }

    /// Commit a handoff op's rows with one advisory journal record.
    pub(crate) fn commit_feed_local_handoff(
        &mut self,
        item: &Item,
        changes: &Changes,
    ) -> anyhow::Result<()> {
        if changes.is_empty() {
            return Ok(());
        }
        let tx = self.connection.transaction()?;
        write_feed_local_changes(&tx, changes)?;
        presentation_store::append_presentation_record(
            &tx,
            "feed.local.handoff",
            Vec::new(),
            &json!({"item_id": item.id, "state": item.state.as_str(), "home": item.home}),
        )?;
        tx.commit()?;
        Ok(())
    }

    /// [`Self::commit_resource_effect_with`] without an extra write.
    pub fn commit_resource_effect(
        &mut self,
        idempotency_key: &str,
        operation: &str,
        fingerprint: &Value,
        outcome: &ResourceEffectOutcome,
        deltas: Option<&Value>,
    ) -> anyhow::Result<u64> {
        self.commit_resource_effect_with(
            idempotency_key,
            operation,
            fingerprint,
            outcome,
            deltas,
            None,
        )
    }

    /// Durably acknowledge notifications, then drop acknowledgements of
    /// notifications no longer retained by committed receipts. `extra` runs
    /// in the same transaction (the local feed reads of the same tab).
    /// Returns how many ids were newly acknowledged.
    pub fn ack_notifications_durable(
        &mut self,
        notification_ids: &[String],
        acked_at_ms: u64,
        subjects: Vec<JournalSubject>,
        extra: Option<RegistryTransactionWrite<'_>>,
    ) -> anyhow::Result<usize> {
        if notification_ids.is_empty() && extra.is_none() {
            return Ok(0);
        }
        let tx = self.connection.transaction()?;
        let mut added = 0;
        for id in notification_ids {
            anyhow::ensure!(
                id.starts_with("notification_") && id.len() <= 64,
                "bad request: invalid notification id {id}"
            );
            added += tx.execute(
                "INSERT OR IGNORE INTO notification_acks(notification_id, acked_at_ms)
                 VALUES(?1, ?2)",
                params![id, i64::try_from(acked_at_ms)?],
            )?;
        }
        tx.execute(
            "DELETE FROM notification_acks WHERE notification_id NOT IN (
               SELECT json_extract(outcome_json, '$.value.id')
               FROM resource_effect_receipts
               WHERE operation = 'notification.create' AND state = 'committed'
                 AND json_extract(outcome_json, '$.value.id') IS NOT NULL
             )",
            [],
        )?;
        if added > 0 {
            presentation_store::append_presentation_record(
                &tx,
                "notification.acknowledged",
                subjects,
                &json!({"notification_ids": notification_ids, "acked_at_ms": acked_at_ms}),
            )?;
        }
        if let Some(extra) = extra {
            extra(&tx)?;
        }
        tx.commit()?;
        Ok(added)
    }
}
