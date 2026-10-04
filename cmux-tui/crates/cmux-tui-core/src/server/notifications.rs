//! Raw protocol handlers of the notification ledger: the per-client tab
//! acknowledgement (which also reads the tab's local feed items,
//! `feed-local-owner-v1`) and the retained-notification list.

use serde_json::{Value, json};

use super::{Mux, SurfaceId};

/// `ack-tab-notifications`. `refused` lists the tab's unread items that the
/// local feed owner could not read because another owner holds them.
pub(super) fn ack_tab(mux: &Mux, surface: SurfaceId) -> anyhow::Result<Value> {
    let ack = mux.acknowledge_tab_notifications(surface)?;
    Ok(json!({
        "surface": surface,
        "cleared": ack.cleared,
        "acknowledged": ack.acknowledged,
        "refused": crate::mux::feed_local::refused_json(&ack.refused),
    }))
}

/// `list-notifications`: retained notifications, newest first, at most 256.
pub(super) fn list(mux: &Mux, limit: Option<usize>) -> anyhow::Result<Value> {
    let rows = mux.notification_rows(limit.unwrap_or(256).min(256))?;
    Ok(json!({
        "notifications": rows
            .iter()
            .map(|(row, acknowledged)| {
                json!({
                    "id": row.id,
                    "title": row.title,
                    "subtitle": row.subtitle,
                    "body": row.body,
                    "level": row.level.as_str(),
                    "terminal_id": row.terminal_id,
                    "surface": row.surface,
                    "created_at_ms": row.created_at_ms,
                    "source": row.source.as_str(),
                    "acknowledged": acknowledged,
                })
            })
            .collect::<Vec<_>>(),
    }))
}
