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
//! `clear_notifications`, the terminal close cleanup, the `feed-local-*`
//! commands) hold no registry or state lock, because each of them already
//! called a registry or state locker of its own before this change. Rings
//! change only under the feed lock, together with the items they follow.

use cmux_feed_core::{
    Actor, Changes, Context as FeedContext, Feed, FeedError, Item, ListFilter, Notice,
};

use std::sync::PoisonError;

use super::*;
use crate::workspace_registry::feed_local_store::{
    feed_item_id, notify_dedupe_key, record_feed_local_folded, write_feed_local_changes,
};

/// The daemon hosts the local feed owner: notifications are local items,
/// selection never clears unread (only `ack-tab-notifications` does), and
/// the `feed-local-*` commands serve the app's handoff (feed.md 9.1).
pub const FEED_LOCAL_OWNER_CAPABILITY: &str = "feed-local-owner-v1";

/// Lock a mutex this module takes. A poisoned lock still holds a consistent
/// value here: the feed copy is installed only after its commit succeeds.
fn lock<T, const R: u16>(mutex: &RankedMutex<T, R>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

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
                    FeedError::Invalid(_) | FeedError::Forbidden(_) => String::new(),
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
        lock(&self.feed_local).list(filter).into_iter().cloned().collect()
    }

    /// Commit a successful `notification.create` effect together with its
    /// local `feed.post` (B2). The post is decided before the commit (B7).
    /// `actor` is the request's actor (B6). The ring and then the
    /// `notification` event follow a successful commit only, so a client
    /// that acknowledges on the event reads the committed item.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn commit_notification_effect(
        &self,
        actor: &crate::Actor,
        idempotency_key: &str,
        fingerprint: &Value,
        outcome: &ResourceEffectOutcome,
        deltas: &Value,
        notification: &ResourceNotification,
        numeric_id: u64,
    ) -> anyhow::Result<u64> {
        let notice = self.feed_notice(notification, actor);
        let item_id = notice.id.clone();
        let mut feed = lock(&self.feed_local);
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
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let revision = registry.commit_resource_effect_with(
            idempotency_key,
            "notification.create",
            fingerprint,
            outcome,
            Some(deltas),
            Some(&write),
        )?;
        *feed = next;
        // The ring goes up with the item, under the feed lock: a read or a
        // tab ack holds this lock while it clears rings, so it sees both the
        // ring and the unread item, or neither.
        let ring = self.raise_notification_ring(notification, numeric_id);
        drop(feed);
        self.state.lock().unwrap_or_else(PoisonError::into_inner).resource_revision = revision;
        drop(registry);
        self.emit(MuxEvent::Notification(NotificationEvent {
            notification: numeric_id,
            title: notification.title.clone(),
            body: notification.body.clone(),
            level: notification.level,
            surface: notification.surface,
            source: notification.source,
        }));
        if ring {
            self.emit(MuxEvent::TreeChanged);
        }
        self.publish_resource_event();
        Ok(revision)
    }

    /// Set the unread marker of a committed notification: on its terminal
    /// (every view of one terminal shares it), else on its placement. Shared
    /// topology focus is only a default projection: a frontend acknowledges
    /// a viewed notification with `ack-tab-notifications`, so focus in one
    /// client cannot hide attention from the others. Caller holds the feed
    /// lock.
    fn raise_notification_ring(&self, notification: &ResourceNotification, id: u64) -> bool {
        let marker = SurfaceNotification {
            notification: id,
            level: notification.level,
            unread: true,
            source: notification.source,
        };
        match (&notification.terminal_id, notification.surface) {
            (Some(terminal), _) => {
                lock(&self.terminal_notifications).insert(terminal.clone(), marker);
                true
            }
            (None, Some(surface)) => {
                lock(&self.placement_notifications).insert(surface, marker);
                true
            }
            (None, None) => false,
        }
    }

    /// `feed-local-read`: read explicit items, all or nothing. A moved item
    /// refuses with `owner.unreachable` (B5); nothing queues. A terminal, or
    /// a tab without a terminal, with no unread local item left loses its
    /// unread marker (`tab-changed` per placement), and its retained ledger
    /// entries are acknowledged in the same transaction, so a restart does
    /// not bring the ring back.
    pub fn feed_local_read(&self, ids: &[String]) -> anyhow::Result<Vec<Item>> {
        let mut feed = lock(&self.feed_local);
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
        let acked: Vec<String> = lock(&self.notification_ledger)
            .iter()
            .filter(|entry| match &entry.terminal_id {
                Some(terminal) => terminals.contains(terminal),
                None => entry.surface.is_some_and(|surface| tab_surfaces.contains(&surface)),
            })
            .map(|entry| entry.id.as_str().to_string())
            .collect();
        let write = |tx: &rusqlite::Transaction<'_>| write_feed_local_changes(tx, &changes);
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .ack_notifications_durable(&acked, now_ms(), Vec::new(), Some(&write))?;
        *feed = next;
        // Clear the markers before the feed lock is released. A notification
        // raises its ring in its commit, under this lock, together with its
        // item, so this sees a newer notification's ring and unread item
        // together (and keeps both) or neither (and its ring comes after).
        let mut cleared = Vec::new();
        let mut markers = lock(&self.terminal_notifications);
        for (terminal, placements) in terminals.iter().zip(terminal_placements) {
            if markers.remove(terminal).is_some() {
                cleared.extend(placements);
            }
        }
        drop(markers);
        let mut placement_markers = lock(&self.placement_notifications);
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
        let mut feed = lock(&self.feed_local);
        let mut next = (*feed).clone();
        let (item, changes) = op(&mut next)?;
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .commit_feed_local_handoff(&item, &changes)?;
        *feed = next;
        Ok(item)
    }

    /// The P8 stamp (identity.md section 3) of a request actor: its wire
    /// kind and id, and this machine for a local actor.
    fn feed_actor(&self, actor: &crate::Actor) -> Actor {
        let wire = actor.wire();
        let (kind, id) = match wire.split_once(':') {
            Some((kind, id)) => (kind.to_string(), id.to_string()),
            None => (wire.clone(), wire),
        };
        let local = !matches!(actor, crate::Actor::Peer { .. } | crate::Actor::Legacy);
        let host = local.then(|| self.machine_public_id.as_str().to_string());
        Actor { kind, id, host, agent: None }
    }

    /// Read every owned unread local item `matches` selects, under the feed
    /// lock: `commit` gets the write of the reads (none when nothing was
    /// read) and the feed as it will be, writes in its own transaction and
    /// says whether it did (false for a replay); only then is the new feed
    /// installed. The feed is not copied when no matching item is unread.
    /// `notification.clear` and the close paths use it, so no unread item
    /// outlives what it points at. Returns whether reads were written.
    pub(crate) fn read_feed_items_in(
        &self,
        matches: impl Fn(&Item) -> bool,
        commit: impl FnOnce(
            Option<crate::workspace_registry::RegistryTransactionWrite<'_>>,
            &Feed,
        ) -> anyhow::Result<bool>,
    ) -> anyhow::Result<bool> {
        let mut feed = lock(&self.feed_local);
        if !feed.items().iter().any(|item| item.is_unread() && matches(item)) {
            commit(None, &feed)?;
            return Ok(false);
        }
        let mut next = (*feed).clone();
        let (changes, _owned_elsewhere) = next.read_where(now_ms(), &matches);
        let write = |tx: &rusqlite::Transaction<'_>| write_feed_local_changes(tx, &changes);
        let wrote = !changes.is_empty();
        if commit(wrote.then_some(&write), &next)? {
            *feed = next;
            return Ok(wrote);
        }
        Ok(false)
    }

    /// Write feed reads (an extra write) in their own registry transaction.
    fn write_feed_reads(
        &self,
        extra: Option<crate::workspace_registry::RegistryTransactionWrite<'_>>,
    ) -> anyhow::Result<()> {
        let Some(extra) = extra else { return Ok(()) };
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        registry.ack_notifications_durable(&[], now_ms(), Vec::new(), Some(extra)).map(drop)
    }

    /// A closed terminal: read its open items and drop its ring, in one step
    /// under the feed lock.
    pub(crate) fn close_terminal_feed_items(&self, terminal: &TerminalPublicId) {
        let of_terminal = |item: &Item| item.context.terminal.as_deref() == Some(terminal.as_str());
        let result = self.read_feed_items_in(of_terminal, |extra, _| {
            self.write_feed_reads(extra)?;
            lock(&self.terminal_notifications).remove(terminal);
            Ok(true)
        });
        self.after_close_feed_read(result, "closed terminal's feed items not read");
        lock(&self.terminal_notifications).remove(terminal);
    }

    /// A closed placement: read the open items of tabs without a terminal
    /// (a browser tab) that are gone, and drop its ring, under the feed lock.
    /// Terminal items follow the terminal (`close_terminal_feed_items`).
    pub(crate) fn close_placement_feed_items(&self, surface: SurfaceId) {
        let live: HashSet<String> = self.with_state(|state| {
            state.resource_indexes.tab_ids.values().map(|tab| tab.as_str().to_string()).collect()
        });
        let gone = |item: &Item| {
            item.context.terminal.is_none()
                && item.context.tab.as_ref().is_some_and(|tab| !live.contains(tab))
        };
        let result = self.read_feed_items_in(gone, |extra, _| {
            self.write_feed_reads(extra)?;
            lock(&self.placement_notifications).remove(&surface);
            Ok(true)
        });
        self.after_close_feed_read(result, "closed tab's feed items not read");
        lock(&self.placement_notifications).remove(&surface);
    }

    fn after_close_feed_read(&self, result: anyhow::Result<bool>, failure: &str) {
        match result {
            Ok(true) => self.publish_journal_event(),
            Ok(false) => {}
            Err(_) => self.report_internal_diagnostic(failure),
        }
    }

    /// Persist the acknowledgement of `ids` (the tab's retained ledger
    /// entries) and read the local items of `terminal` in one transaction,
    /// then clear the tab's marker. Returns whether a marker cleared, whether
    /// `ids` were acked (not while an unread item is left), and the unread
    /// items it could not read (owned elsewhere).
    pub(crate) fn ack_notifications_and_feed(
        &self,
        ids: &[String],
        terminal: Option<&TerminalPublicId>,
        surface: SurfaceId,
        subjects: Vec<crate::JournalSubject>,
    ) -> anyhow::Result<(bool, bool, Vec<FeedError>)> {
        // A placement without a terminal (a browser tab) is matched by its tab.
        let tab = self.with_state(|state| {
            state.resource_indexes.tab_ids.get(&surface).map(|tab| tab.as_str().to_string())
        });
        let of_tab = |item: &Item| match (terminal, &tab) {
            (Some(terminal), _) => item.context.terminal.as_deref() == Some(terminal.as_str()),
            (None, Some(tab)) => {
                item.context.terminal.is_none() && item.context.tab.as_deref() == Some(tab)
            }
            (None, None) => false,
        };
        let mut feed = lock(&self.feed_local);
        let mut next = (*feed).clone();
        let (changes, refused) = next.read_where(now_ms(), of_tab);
        // Rings follow unread items (9.1 rule 6): an item another owner holds
        // stays unread here, and so does its ring.
        let unread_left = next.items().iter().any(|item| item.is_unread() && of_tab(item));
        let write = |tx: &rusqlite::Transaction<'_>| write_feed_local_changes(tx, &changes);
        let extra: Option<crate::workspace_registry::RegistryTransactionWrite<'_>> =
            (!changes.is_empty()).then_some(&write);
        // An unread item left keeps its ring, also after a restart: the tab's
        // notifications are acked durably only when nothing of it stays unread.
        let ids = if unread_left { &[][..] } else { ids };
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .ack_notifications_durable(ids, now_ms(), subjects, extra)?;
        *feed = next;
        // The marker clears under the feed lock (see `raise_notification_ring`).
        let cleared = !unread_left
            && match terminal {
                Some(terminal) => lock(&self.terminal_notifications).remove(terminal).is_some(),
                None => lock(&self.placement_notifications).remove(&surface).is_some(),
            };
        Ok((cleared, !unread_left, refused))
    }

    /// The local notice for one committed notification: dedupe key
    /// `notify:<daemon session>:<notification id>`, context from its
    /// placement, and the request's actor (B6, never part of a fingerprint).
    /// A notice with no terminal and no tab posts read: no tab ack could
    /// ever read it.
    fn feed_notice(&self, notification: &ResourceNotification, actor: &crate::Actor) -> Notice {
        let session = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .session_id()
            .clone();
        let (workspace, tab) = notification
            .surface
            .map(|surface| {
                let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
                let workspace = state
                    .pane_of(surface)
                    .and_then(|pane| state.screen_of(pane))
                    .and_then(|(workspace, _)| state.workspaces.get(workspace))
                    .map(|workspace| workspace.public_id.as_str().into());
                let tab = state
                    .resource_indexes
                    .tab_ids
                    .get(&surface)
                    .map(|tab| tab.as_str().to_string());
                (workspace, tab)
            })
            .unwrap_or_default();
        let terminal = notification.terminal_id.as_ref().map(|id| id.as_str().to_string());
        Notice {
            id: feed_item_id(&notification.id),
            dedupe_key: notify_dedupe_key(&session, &notification.id),
            title: notification.title.clone(),
            body: notification.body.clone(),
            level: notification.level.as_str().to_string(),
            source: notification.source.as_str().to_string(),
            read: terminal.is_none() && tab.is_none(),
            context: FeedContext { workspace, tab, terminal },
            actor: Some(self.feed_actor(actor)),
            at_ms: notification.created_at_ms,
            coalesce: true,
        }
    }
}
