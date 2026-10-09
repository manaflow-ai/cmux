//! Storage of the palette usage history (`palette-usage-v1`): one row of
//! the home session's workspace store. The reducer is
//! [`super::palette_usage`]; [`super::palette_usage_ops`] commits it.

use rusqlite::{Connection, OptionalExtension, Transaction};
use serde_json::{Value, json};

use super::palette_usage::{self, Document, decayed, decayed_pick};

/// `palette_usage.get|record|import`.
pub const CAPABILITY: &str = "palette-usage-v1";
/// The resource kind of the history on `session.events`.
pub(crate) const RESOURCE: &str = "palette_usage";
/// The id of the one history (per user, so per home session).
pub(crate) const ID: &str = "user";
/// The largest stored document; the reducer's bounds keep it far below.
pub(crate) const MAX_DOCUMENT_BYTES: usize = 2 * 1024 * 1024;

pub(crate) fn create_palette_usage_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS palette_usage (
           id INTEGER PRIMARY KEY CHECK(id = 1),
           document_json TEXT NOT NULL
         );",
    )?;
    Ok(())
}

/// The stored history, or an empty one when it was never written or the row
/// no longer parses (the next record replaces a damaged row).
pub(crate) fn document(connection: &Connection) -> anyhow::Result<Document> {
    let stored: Option<String> = connection
        .query_row("SELECT document_json FROM palette_usage WHERE id = 1", [], |row| row.get(0))
        .optional()?;
    Ok(match stored.map(|text| serde_json::from_str::<Document>(&text)) {
        Some(Ok(document)) => document,
        Some(Err(error)) => {
            eprintln!("cmux-tui: palette usage row does not parse ({error}); starting empty");
            Document::default()
        }
        None => Document::default(),
    })
}

pub(crate) fn write_document(
    transaction: &Transaction<'_>,
    document: &Document,
) -> anyhow::Result<()> {
    let json = serde_json::to_string(document)?;
    anyhow::ensure!(
        json.len() <= MAX_DOCUMENT_BYTES,
        "bad request: the palette usage history would exceed {MAX_DOCUMENT_BYTES} bytes"
    );
    transaction.execute(
        "INSERT INTO palette_usage(id, document_json) VALUES(1, ?1)
         ON CONFLICT(id) DO UPDATE SET document_json = excluded.document_json",
        [json],
    )?;
    Ok(())
}

fn row(key: &str, entry: &palette_usage::Entry) -> Value {
    json!({"key": key, "score": entry.score, "last_used_ms": entry.last_used_ms.to_string()})
}

fn pick(prefix: &str, key: &str, entry: &palette_usage::Entry, last: bool) -> Value {
    json!({
        "prefix": prefix, "key": key, "score": entry.score,
        "last_used_ms": entry.last_used_ms.to_string(), "last": last,
    })
}

/// `PaletteUsageSnapshot`: rows and learned picks as arrays (most used
/// first), scores as stored (as of `last_used_ms`), the half-lives, and the
/// revision as a decimal string. `now_ms` only orders the arrays.
pub(crate) fn snapshot_value(document: &Document, now_ms: u64) -> Value {
    let mut entries: Vec<_> = document.entries.iter().collect();
    entries.sort_by(|left, right| {
        decayed(right.1, now_ms).total_cmp(&decayed(left.1, now_ms)).then(left.0.cmp(right.0))
    });
    let mut picks = Vec::new();
    for (prefix, rows) in &document.picks {
        let mut sorted: Vec<_> = rows.rows.iter().collect();
        sorted.sort_by(|left, right| {
            decayed_pick(right.1, now_ms)
                .total_cmp(&decayed_pick(left.1, now_ms))
                .then(left.0.cmp(right.0))
        });
        picks.extend(
            sorted.into_iter().map(|(key, entry)| pick(prefix, key, entry, *key == rows.last)),
        );
    }
    json!({
        "revision": document.revision.to_string(),
        "half_life_ms": palette_usage::HALF_LIFE_MS.to_string(),
        "pick_half_life_ms": palette_usage::PICK_HALF_LIFE_MS.to_string(),
        "entries": entries.into_iter().map(|(key, entry)| row(key, entry)).collect::<Vec<_>>(),
        "picks": picks,
        "imported": document.imported,
    })
}

pub(crate) fn snapshot(connection: &Connection) -> anyhow::Result<Value> {
    Ok(snapshot_value(&document(connection)?, super::palette_usage_ops::now_ms()))
}
