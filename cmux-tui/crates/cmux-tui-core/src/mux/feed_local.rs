//! The daemon's local feed owner (`feed-local-owner-v1`, plans/cmux-next/
//! feed.md section 9.1, B1 to B7).
//!
//! Every notification the daemon commits is also a local `feed.post` in the
//! same transaction (B2). The reducer decides creation or coalescing (B7)
//! on a copy before the commit; the copy replaces the live feed only after
//! the commit succeeds, so memory never shows an item the store lost.
//!
//! Lock order: `feed_local` before `workspace_registry` before `state`.
//! Every function here that locks `feed_local` holds neither of the others
//! when it does; it releases its own `state` and registry reads (`feed_notice`,
//! the tab lookup in `ack_notifications_and_feed`) before it locks
//! `feed_local`. Its callers (`create_durable_notification`, the v2
//! `notification.create` effect, `acknowledge_tab_notifications`,
//! `clear_surface_notification`, the `feed-local-*` commands) hold no registry
//! or state lock, because each of them already called a registry or state
//! locker of its own before this change.

use cmux_feed_core::{
    Actor, Changes, Context as FeedContext, Feed, FeedError, Item, ListFilter, Notice,
};

use super::*;
use crate::workspace_registry::feed_local_store::{
    feed_item_id, notify_dedupe_key, record_feed_local_folded, write_feed_local_changes,
};

/// The daemon hosts the local feed owner: notifications are local items,
/// selection never clears unread (only `ack-tab-notifications` does), and
/// the `feed-local-*` commands serve the app's handoff (feed.md 9.1).
pub const FEED_LOCAL_OWNER_CAPABILITY: &str = "feed-local-owner-v1";

/// The wire code of a refused feed op, for the raw protocol's `error_code`.
pub(crate) fn feed_error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<FeedError>().map(|error| error.code().to_string())
}

/// What `ack-tab-notifications` could not read: items owned elsewhere.
pub(crate) fn refused_json(refused: &[FeedError]) -> Value {
    Value::Array(
        refused
            .iter()
            .map(|error| {
                let item = match error {
                    FeedError::Moving(item)
                    | FeedError::NotFound(item)
                    | FeedError::OwnerUnreachable { item, .. }
                    | FeedError::InvalidState { item, .. } => item.clone(),
                    FeedError::Invalid(_) => String::new(),
                };
                serde_json::json!({
                    "item": item,
                    "code": error.code(),
                    "retryable": error.retryable(),
                })
            })
            .collect(),
    )
}

impl Mux {
    /// The local owner's items matching `filter`, oldest first.
    pub fn feed_local_list(&self, filter: &ListFilter) -> Vec<Item> {
        self.feed_local.lock().unwrap().list(filter).into_iter().cloned().collect()
    }

    /// Commit a successful `notification.create` effect together with its
    /// local `feed.post` (B2). The post is decided before the commit (B7).
    pub(crate) fn commit_notification_effect(
        &self,
        idempotency_key: &str,
        fingerprint: &Value,
        outcome: &ResourceEffectOutcome,
        deltas: &Value,
        notification: &ResourceNotification,
    ) -> anyhow::Result<u64> {
        let notice = self.feed_notice(notification);
        let item_id = notice.id.clone();
        let mut feed = self.feed_local.lock().unwrap();
        let mut next = (*feed).clone();
        // The item that took the notice (its own, or the one it coalesced
        // into); the folded set records it so the ledger pass never posts
        // the notice again.
        let mut folded_into = None;
        let changes = match next.post(notice) {
            Ok((outcome, changes)) => {
                folded_into = Some(outcome.item().id.clone());
                changes
            }
            Err(error) => {
                // The notification still commits; the feed keeps its old copy.
                eprintln!("cmux-tui: local feed post of item {item_id} refused: {error}");
                self.report_internal_diagnostic(format!(
                    "local feed post of item {item_id} refused: {}",
                    error.code()
                ));
                next = (*feed).clone();
                Changes::default()
            }
        };
        let write = |tx: &rusqlite::Transaction<'_>| {
            write_feed_local_changes(tx, &changes)?;
            match &folded_into {
                Some(item) => record_feed_local_folded(
                    tx,
                    notification.id.as_str(),
                    item,
                    notification.created_at_ms,
                ),
                None => Ok(()),
            }
        };
        let mut registry = self.workspace_registry.lock().unwrap();
        let revision = registry.commit_resource_effect_with(
            idempotency_key,
            "notification.create",
            fingerprint,
            outcome,
            Some(deltas),
            Some(&write),
        )?;
        *feed = next;
        drop(feed);
        self.state.lock().unwrap().resource_revision = revision;
        drop(registry);
        self.publish_resource_event();
        Ok(revision)
    }

    /// `feed-local-read`: read explicit items, all or nothing. A moved item
    /// refuses with `owner.unreachable` (B5); nothing queues. A terminal, or
    /// a tab without a terminal, with no unread local item left loses its
    /// unread marker (`tab-changed` per placement), and its retained ledger
    /// entries are acknowledged in the same transaction, so a restart does
    /// not bring the ring back.
    pub fn feed_local_read(&self, ids: &[String]) -> anyhow::Result<Vec<Item>> {
        let mut feed = self.feed_local.lock().unwrap();
        let mut next = (*feed).clone();
        let changes = next.read(ids, now_ms())?;
        if changes.is_empty() {
            return Ok(ids.iter().filter_map(|id| next.get(id).cloned()).collect());
        }
        // A terminal, or a tab without a terminal, settles when this read
        // left it no unread item: its ledger entries are acknowledged in the
        // same transaction and its ring clears, as `ack-tab-notifications`
        // would do.
        let unread_left = |matches: &dyn Fn(&Item) -> bool| {
            next.items().iter().any(|item| item.is_unread() && matches(item))
        };
        let mut terminals: Vec<TerminalPublicId> = Vec::new();
        let mut tabs: Vec<String> = Vec::new();
        for item in &changes.upserts {
            match (&item.context.terminal, &item.context.tab) {
                (Some(terminal), _) => {
                    if !unread_left(&|other| other.context.terminal.as_ref() == Some(terminal))
                        && let Ok(id) = TerminalPublicId::parse(terminal)
                        && !terminals.contains(&id)
                    {
                        terminals.push(id);
                    }
                }
                (None, Some(tab)) => {
                    if !unread_left(&|other| {
                        other.context.terminal.is_none() && other.context.tab.as_ref() == Some(tab)
                    }) && !tabs.contains(tab)
                    {
                        tabs.push(tab.clone());
                    }
                }
                (None, None) => {}
            }
        }
        let (tab_surfaces, terminal_placements) = self.with_state(|state| {
            let tab_surfaces: Vec<SurfaceId> = state
                .resource_indexes
                .tab_ids
                .iter()
                .filter(|(_, tab)| tabs.iter().any(|settled| settled == tab.as_str()))
                .map(|(surface, _)| *surface)
                .collect();
            let placements: Vec<Vec<SurfaceId>> = terminals
                .iter()
                .map(|terminal| {
                    state
                        .placements_of_content(&ContentPublicId::Terminal(terminal.clone()))
                        .to_vec()
                })
                .collect();
            (tab_surfaces, placements)
        });
        let acked: Vec<String> = self
            .notification_ledger
            .lock()
            .unwrap()
            .iter()
            .filter(|entry| match &entry.terminal_id {
                Some(terminal) => terminals.contains(terminal),
                None => entry.surface.is_some_and(|surface| tab_surfaces.contains(&surface)),
            })
            .map(|entry| entry.id.as_str().to_string())
            .collect();
        let write = |tx: &rusqlite::Transaction<'_>| write_feed_local_changes(tx, &changes);
        self.workspace_registry.lock().unwrap().ack_notifications_durable(
            &acked,
            now_ms(),
            Vec::new(),
            Some(&write),
        )?;
        *feed = next;
        // Clear the markers before the feed lock is released: a notification
        // that commits after this read takes the feed lock first and sets its
        // marker only after its commit, so this cannot clear a newer ring.
        let mut cleared = Vec::new();
        let mut markers = self.terminal_notifications.lock().unwrap();
        for (terminal, placements) in terminals.iter().zip(terminal_placements) {
            if markers.remove(terminal).is_some() {
                cleared.extend(placements);
            }
        }
        drop(markers);
        let mut placement_markers = self.placement_notifications.lock().unwrap();
        cleared.extend(
            tab_surfaces.into_iter().filter(|surface| placement_markers.remove(surface).is_some()),
        );
        drop(placement_markers);
        drop(feed);
        if !cleared.is_empty() {
            for placement in cleared {
                self.emit_tab_changed(placement);
            }
            self.emit(MuxEvent::TreeChanged);
        }
        self.publish_journal_event();
        Ok(changes.upserts)
    }

    /// `feed-local-handoff-begin`: freeze an item before the app sends
    /// `feed.adopt` with key `adopt:<item>` (section 5 rule 3a).
    pub fn feed_local_handoff_begin(&self, id: &str) -> anyhow::Result<Item> {
        self.feed_local_handoff(|feed| feed.handoff_begin(id, now_ms()))
    }

    /// `feed-local-handoff-abort`: `feed.adopt.cancel` answered `cancelled:
    /// true`, so the item is owned here again. Repeating it is a no-op.
    pub fn feed_local_handoff_abort(&self, id: &str) -> anyhow::Result<Item> {
        self.feed_local_handoff(|feed| feed.handoff_abort(id, now_ms()))
    }

    /// `feed-local-handoff-done`: the new owner committed the item; it moves
    /// to `home` (section 5 rule 3d). Repeating it is a no-op.
    pub fn feed_local_handoff_done(&self, id: &str, home: &str) -> anyhow::Result<Item> {
        self.feed_local_handoff(|feed| feed.handoff_done(id, home, now_ms()))
    }

    fn feed_local_handoff(
        &self,
        op: impl FnOnce(&mut Feed) -> Result<(Item, Changes), FeedError>,
    ) -> anyhow::Result<Item> {
        let mut feed = self.feed_local.lock().unwrap();
        let mut next = (*feed).clone();
        let (item, changes) = op(&mut next)?;
        self.workspace_registry.lock().unwrap().commit_feed_local_handoff(&item, &changes)?;
        *feed = next;
        Ok(item)
    }

    /// Persist the acknowledgement of `ids` (the tab's retained ledger
    /// entries) and read the local items of `terminal` in one transaction.
    /// Returns the unread items it could not read (owned elsewhere).
    pub(crate) fn ack_notifications_and_feed(
        &self,
        ids: &[String],
        terminal: Option<&TerminalPublicId>,
        surface: SurfaceId,
        subjects: Vec<crate::JournalSubject>,
    ) -> anyhow::Result<Vec<FeedError>> {
        // A placement without a terminal (a browser tab) is matched by its tab.
        let tab = self.with_state(|state| {
            state.resource_indexes.tab_ids.get(&surface).map(|tab| tab.as_str().to_string())
        });
        let mut feed = self.feed_local.lock().unwrap();
        let mut next = (*feed).clone();
        let (changes, refused) = match (terminal, tab) {
            (Some(terminal), _) => next.read_terminal(terminal.as_str(), now_ms()),
            (None, Some(tab)) => next.read_where(now_ms(), |item| {
                item.context.terminal.is_none() && item.context.tab.as_deref() == Some(&tab)
            }),
            (None, None) => (Changes::default(), Vec::new()),
        };
        let write = |tx: &rusqlite::Transaction<'_>| write_feed_local_changes(tx, &changes);
        let extra: Option<crate::workspace_registry::RegistryTransactionWrite<'_>> =
            (!changes.is_empty()).then_some(&write);
        self.workspace_registry.lock().unwrap().ack_notifications_durable(
            ids,
            now_ms(),
            subjects,
            extra,
        )?;
        *feed = next;
        Ok(refused)
    }

    /// The local notice for one committed notification: dedupe key
    /// `notify:<daemon session>:<notification id>`, context and actor (B6)
    /// from its terminal. The actor is not part of any fingerprint.
    fn feed_notice(&self, notification: &ResourceNotification) -> Notice {
        let session = self.workspace_registry.lock().unwrap().session_id().clone();
        let (workspace, tab) = notification
            .surface
            .map(|surface| {
                let state = self.state.lock().unwrap();
                let workspace = state
                    .pane_of(surface)
                    .and_then(|pane| state.screen_of(pane))
                    .map(|(workspace, _)| state.workspaces[workspace].public_id.as_str().into());
                let tab = state
                    .resource_indexes
                    .tab_ids
                    .get(&surface)
                    .map(|tab| tab.as_str().to_string());
                (workspace, tab)
            })
            .unwrap_or_default();
        let terminal = notification.terminal_id.as_ref().map(|id| id.as_str().to_string());
        // The P8 stamp (identity.md section 3): a notice from a terminal
        // (an agent's too) names that terminal and its host; one without a
        // terminal came from the local user's connection.
        let actor = match terminal.clone() {
            Some(id) => Actor {
                kind: "terminal".into(),
                id,
                host: Some(self.machine_public_id.as_str().to_string()),
                agent: None,
            },
            None => Actor { kind: "user".into(), id: "user_local".into(), host: None, agent: None },
        };
        Notice {
            id: feed_item_id(&notification.id),
            dedupe_key: notify_dedupe_key(&session, &notification.id),
            title: notification.title.clone(),
            body: notification.body.clone(),
            level: notification.level.as_str().to_string(),
            source: notification.source.as_str().to_string(),
            context: FeedContext { workspace, tab, terminal },
            actor: Some(actor),
            at_ms: notification.created_at_ms,
            read: false,
            coalesce: true,
        }
    }
}

#[cfg(test)]
#[path = "feed_local_tests.rs"]
mod tests;
