//! Part of `ConversationStore`: a window of one caller's Home list
//! (`home-inbox` with `offset`/`limit` or `ids`), built only for its rows.
//!
//! The whole list (`list` then `cmux_conversation::home_inbox`) reads every
//! conversation's head, cursors, guards and last message and builds every
//! row. A window needs the order alone for the list ([`HomeOrder`]: ids,
//! participants, titles, times, pins: one query), then the window's own heads
//! and last messages. The order is kept until the store changes (SQLite's
//! `total_changes()` for this connection, `PRAGMA data_version` for any
//! other) or the caller or the deleted Chiefs differ, so a Home open after
//! no change reads only its window.
//!
//! The caller's pins and marks are the store's own (`inbox_state`, the same
//! connection, so a pin bumps `total_changes()`): they are read here, all of
//! them only when the order is built, else only the window's.

use std::collections::BTreeSet;
use std::sync::Arc;

use anyhow::Context;
use cmux_conversation::{
    HomeHead, HomeInboxInput, HomeOrder, HomeRow, HomeScope, HomeWindow, Summary,
};

use super::{ConversationStore, load_head, load_message_by_seq, summary};

/// What a kept order was made from.
#[derive(Debug, Clone, PartialEq, Eq)]
struct OrderKey {
    total_changes: i64,
    data_version: i64,
    me: String,
    scope: HomeScope,
    deleted_chiefs: BTreeSet<String>,
}

/// The last order built, and what it was built from.
#[derive(Debug, Default)]
pub(crate) struct HomeOrderCache {
    kept: Option<(OrderKey, Arc<HomeOrder>)>,
}

/// One window read.
#[derive(Debug)]
pub(crate) struct HomeWindowRead {
    /// The window's rows, each with its index in the whole list.
    pub rows: Vec<(usize, HomeRow)>,
    /// The whole list's order.
    pub order: Arc<HomeOrder>,
    /// Whether the order was read from the store (false: the kept one).
    pub ordered_now: bool,
}

impl ConversationStore {
    /// The window of `input.me`'s Home list (local conversations in `scope`).
    /// `input.states` is not read: the caller's pins and marks are read from
    /// the store (all of them only when the order is built).
    pub(crate) fn home_window(
        &mut self,
        input: &mut HomeInboxInput<'_>,
        window: &HomeWindow,
        scope: HomeScope,
    ) -> anyhow::Result<HomeWindowRead> {
        let (order, ordered_now) = self.home_order(input, scope)?;
        let transaction = self.connection.transaction()?;
        let selected = order.select(window);
        // The window's own pins and marks: a row reads only its own.
        input.states.clear();
        for (_, id) in &selected {
            let state = super::inbox::load(&transaction, input.me, id)?;
            if state != Default::default() {
                input.states.insert((*id).to_owned(), home_state(state));
            }
        }
        let mut rows = Vec::new();
        for (at, id) in selected {
            // A conversation that went since the order was read: not in the window.
            let Some(head) = load_head(&transaction, id)? else { continue };
            let last = load_message_by_seq(&transaction, id, head.last_seq)?;
            rows.push((at, order.row(&summary(&head, last.as_ref()), input)));
        }
        drop(transaction);
        Ok(HomeWindowRead { rows, order, ordered_now })
    }

    /// The order of `input.me`'s Home list: the kept one while nothing it
    /// was made from changed, else read again.
    fn home_order(
        &mut self,
        input: &mut HomeInboxInput<'_>,
        scope: HomeScope,
    ) -> anyhow::Result<(Arc<HomeOrder>, bool)> {
        let total_changes: i64 =
            self.connection.query_row("SELECT total_changes()", [], |row| row.get(0))?;
        let data_version: i64 =
            self.connection.query_row("PRAGMA data_version", [], |row| row.get(0))?;
        let key = OrderKey {
            total_changes,
            data_version,
            me: input.me.to_string(),
            scope,
            deleted_chiefs: input.deleted_chiefs.clone(),
        };
        if let Some((kept, order)) = &self.home_order_cache.kept
            && *kept == key
        {
            return Ok((Arc::clone(order), false));
        }
        input.states =
            self.inbox_states(input.me)?.into_iter().map(|(id, s)| (id, home_state(s))).collect();
        let heads = self.home_heads()?;
        let refs: Vec<HomeHead<'_>> =
            heads.iter().map(|(summary, activity_at)| HomeHead { summary, activity_at }).collect();
        let order = Arc::new(HomeOrder::scoped(&refs, input, scope));
        self.home_order_cache.kept = Some((key, Arc::clone(&order)));
        Ok((order, true))
    }

    /// Every conversation's head as the order reads it (no cursors, no last
    /// message), with its activity time: one query.
    fn home_heads(&mut self) -> anyhow::Result<Vec<(Summary, String)>> {
        let mut statement = self.connection.prepare(
            "SELECT c.id, c.title, c.participants_json, c.last_seq, c.rev, c.created_at,
                    c.updated_at, json_extract(m.message_json, '$.created_at')
             FROM conversation c
             LEFT JOIN message m ON m.conversation = c.id AND m.seq = c.last_seq",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
                row.get::<_, Option<String>>(7)?,
            ))
        })?;
        rows.map(|row| {
            let (id, title, participants, last_seq, rev, created_at, updated_at, last_at) = row?;
            let activity_at = last_at.unwrap_or_else(|| updated_at.clone());
            let summary = Summary {
                id,
                owner: cmux_conversation::OWNER_LOCAL.to_string(),
                title,
                participants: serde_json::from_str(&participants)
                    .context("conversation participants are corrupt")?,
                last_seq: u64::try_from(last_seq).context("conversation last_seq is negative")?,
                rev: u64::try_from(rev).context("conversation rev is negative")?,
                created_at,
                updated_at,
                last_message: None,
                read_cursors: Default::default(),
            };
            Ok((summary, activity_at))
        })
        .collect()
    }
}

#[cfg(test)]
#[path = "conversation_home_window_tests.rs"]
mod tests;

/// A pin and mark as the Home projection reads them.
fn home_state(state: super::inbox::InboxState) -> cmux_conversation::HomeListState {
    cmux_conversation::HomeListState {
        pinned: state.pinned,
        pin_position: state.pin_position,
        marked_unread: state.marked_unread,
    }
}
