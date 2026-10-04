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
//! `feed_local_folded` records each notification the local owner took, in
//! the transaction that took it, whatever happened to its item later
//! (coalesced into another item, moved, pruned). A row lives as long as the
//! notification can appear in the ledger window: the pass drops rows whose
//! notification was cleared or whose receipt is gone. Neither a row count nor
//! wall-clock time bounds it, because a clear moves the window back past any
//! fixed depth and clocks can jump.
//!
//! On every open the notification ledger is folded into items (B4): an entry
//! that is not in the folded set becomes an item, READ when any client's
//! `read_by` mark or a persisted ack exists (this also picks up what an older
//! daemon wrote after a downgrade). For a folded entry only a persisted ack
//! counts: it reads the item when it is still open here, as the live ack
//! would have. The meta marker [`FEED_LOCAL_MIGRATION_META_KEY`] records the
//! first pass.

use cmux_feed_core::{Changes, Context as FeedContext, Feed, Item, ItemState, Notice, PostOutcome};
use rusqlite::{Transaction, params};
use serde_json::json;
use sha2::{Digest, Sha256};

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
         CREATE INDEX IF NOT EXISTS feed_local_items_state ON feed_local_items(state);
         CREATE TABLE IF NOT EXISTS feed_local_folded (
           notification_id TEXT PRIMARY KEY NOT NULL,
           item_id TEXT NOT NULL,
           created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0)
         );",
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

/// Record in the caller's transaction that the local owner took
/// `notification` into `item`.
pub(crate) fn record_feed_local_folded(
    transaction: &Transaction<'_>,
    notification: &str,
    item: &str,
    created_at_ms: u64,
) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT OR IGNORE INTO feed_local_folded(notification_id, item_id, created_at_ms)
         VALUES(?1, ?2, ?3)",
        params![notification, item, i64::try_from(created_at_ms)?],
    )?;
    Ok(())
}

/// Drop folded rows that no ledger window can name again: the notification
/// was cleared, or its `notification.create` receipt is gone.
fn trim_feed_local_folded(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute(
        "DELETE FROM feed_local_folded
         WHERE notification_id IN (SELECT notification_id FROM resource_notification_clears)
            OR notification_id NOT IN (
              SELECT json_extract(outcome_json, '$.value.id')
              FROM resource_effect_receipts
              WHERE operation = 'notification.create'
                AND json_extract(outcome_json, '$.value.id') IS NOT NULL)",
        [],
    )?;
    Ok(())
}

/// The local item id for the notification that creates it, derived from the
/// notification's public id so the migration and a live post agree. It has
/// the cloud owner's item id shape (`fi_` plus 20 of `[a-z0-9]`), because
/// `feed.adopt` keeps the id and FeedDO refuses any other shape.
pub(crate) fn feed_item_id(notification: &NotificationPublicId) -> String {
    let digest = Sha256::digest(format!("cmux-feed-item:{}", notification.as_str()));
    let hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("fi_{}", &hex[..20])
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

    /// Run the ledger pass, then load the local owner's items.
    pub(crate) fn open_feed_local(&mut self) -> anyhow::Result<Feed> {
        self.migrate_feed_local_from_ledger()?;
        Ok(Feed::from_items(self.feed_local_items()?))
    }

    /// B4, on every open (at most 256 entries); see the module comment.
    /// Read is one-way. Returns how many items it added.
    pub(crate) fn migrate_feed_local_from_ledger(&mut self) -> anyhow::Result<usize> {
        let live = self.live_terminal_public_ids()?;
        let entries = self.durable_notifications(&live)?;
        let acked = self.acked_notification_ids()?;
        let folded = self.feed_local_folded()?;
        let mut feed = Feed::from_items(self.feed_local_items()?);
        let session = self.session_id().clone();
        let now = unix_epoch_ms()?;
        let mut changes = Changes::default();
        let mut newly_folded = Vec::new();
        let mut added = 0;
        for entry in entries {
            let notification = entry.id.as_str().to_string();
            let key = notify_dedupe_key(&session, &entry.id);
            // A folded entry, or (before the folded set existed) one whose
            // item still carries its key: only a persisted ack reads it.
            let existing = match folded.get(&notification) {
                Some(item) => Some(item.clone()),
                None => feed.find_key(&key).map(|item| item.id.clone()),
            };
            if let Some(item_id) = existing {
                if !folded.contains_key(&notification) {
                    newly_folded.push((notification.clone(), item_id.clone(), entry.created_at_ms));
                }
                let open_unread = feed
                    .get(&item_id)
                    .is_some_and(|item| item.is_unread() && item.state == ItemState::Open);
                if acked.contains(&notification) && open_unread {
                    changes.upserts.extend(feed.read(&[item_id], now)?.upserts);
                }
                continue;
            }
            let read = !entry.read_by.is_empty() || acked.contains(&notification);
            // A read entry past retention would be pruned at once; skip it so
            // every open does not re-add it.
            if read && now.saturating_sub(entry.created_at_ms) >= cmux_feed_core::RETENTION_MS {
                continue;
            }
            let notice = Notice {
                id: feed_item_id(&entry.id),
                dedupe_key: key,
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
                read,
                coalesce: false,
            };
            // An entry the reducer refuses (an id already taken under another
            // key) stays out and unfolded; the ledger keeps it until evicted.
            // Pruning is the reducer's job on the next live op.
            if let Ok((PostOutcome::Created(item), posted)) = feed.post_unpruned(notice) {
                changes.upserts.extend(posted.upserts);
                newly_folded.push((notification, item.id, entry.created_at_ms));
                added += 1;
            }
        }
        let marked = meta_value(&self.connection, FEED_LOCAL_MIGRATION_META_KEY)?.is_some();
        let tx = self.connection.transaction()?;
        trim_feed_local_folded(&tx)?;
        if changes.is_empty() && newly_folded.is_empty() && marked {
            tx.commit()?;
            return Ok(0);
        }
        write_feed_local_changes(&tx, &changes)?;
        for (notification, item, created_at_ms) in &newly_folded {
            record_feed_local_folded(&tx, notification, item, *created_at_ms)?;
        }
        if !marked {
            tx.execute(
                "INSERT INTO meta(key, value) VALUES(?1, ?2)",
                params![FEED_LOCAL_MIGRATION_META_KEY, added.to_string()],
            )?;
        }
        tx.commit()?;
        Ok(added)
    }

    /// Notification id -> item id of every folded notification.
    pub(crate) fn feed_local_folded(&self) -> anyhow::Result<HashMap<String, String>> {
        let mut statement =
            self.connection.prepare("SELECT notification_id, item_id FROM feed_local_folded")?;
        let rows = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    /// Drop every local item and the migration marker, as a registry written
    /// by a daemon without the local owner.
    #[cfg(test)]
    pub(crate) fn forget_feed_local_for_test(&mut self) -> anyhow::Result<()> {
        self.connection.execute("DELETE FROM feed_local_items", [])?;
        self.connection.execute("DELETE FROM feed_local_folded", [])?;
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
            self.connection.execute("DELETE FROM feed_local_folded WHERE item_id = ?1", [id])?;
        }
        Ok(())
    }

    /// Drop item rows only, as the reducer's prune does: every other record
    /// of the notification stays.
    #[cfg(test)]
    pub(crate) fn prune_feed_local_rows_for_test(&mut self, ids: &[String]) -> anyhow::Result<()> {
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
