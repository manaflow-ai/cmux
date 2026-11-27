//! The agent message tables (plans/feat-agent-rooms/DESIGN.md) and the
//! rebuild of the delivery table for per-recipient policy states.
//!
//! The first delivery table knew four states (`queued`, `delivered`,
//! `acknowledged`, `failed`) in a CHECK constraint, which SQLite cannot
//! alter. A registry that still has it is rebuilt once, inside the schema
//! transaction: the rows are copied to a table with every state, the old
//! table is dropped and the new one takes its name. The four old states keep
//! their meaning, so each row keeps its state; the new timestamps are filled
//! from what the old row knew. The new columns have defaults, so an older
//! binary that opens the registry still inserts and reads its rows.
//!
//! `agent_message_threads` counts each thread's messages for the thread
//! budget, so pruning old messages never resets it; a registry without it
//! starts from the messages it holds.

use rusqlite::{OptionalExtension, Transaction};

/// Every delivery state, in the order a delivery usually moves.
pub(crate) const DELIVERY_STATES: [&str; 8] =
    ["held", "queued", "delivered", "acknowledged", "failed", "unsent", "retracted", "declined"];

const DELIVERIES_TABLE: &str = "agent_message_deliveries (
           message_id TEXT NOT NULL,
           recipient TEXT NOT NULL,
           position INTEGER NOT NULL CHECK(position >= 0),
           state TEXT NOT NULL
             CHECK(state IN ('held','queued','delivered','acknowledged','failed',
                             'unsent','retracted','declined')),
           attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts >= 0),
           updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
           via TEXT,
           error TEXT,
           created_at_ms INTEGER NOT NULL DEFAULT 0 CHECK(created_at_ms >= 0),
           queued_at_ms INTEGER,
           delivered_at_ms INTEGER,
           acknowledged_at_ms INTEGER,
           held_until_ms INTEGER,
           reason TEXT,
           PRIMARY KEY(message_id, recipient)
         )";

pub(crate) fn create_agent_message_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS agent_messages (
           message_id TEXT PRIMARY KEY NOT NULL,
           sequence INTEGER NOT NULL UNIQUE,
           thread_id TEXT NOT NULL,
           kind TEXT NOT NULL CHECK(kind IN ('message','reply')),
           sender TEXT NOT NULL,
           sender_name TEXT,
           body TEXT NOT NULL,
           created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
           in_reply_to TEXT,
           references_json TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS agent_messages_thread
           ON agent_messages(thread_id, sequence);
         CREATE INDEX IF NOT EXISTS agent_messages_sender
           ON agent_messages(sender, created_at_ms);
         CREATE TABLE IF NOT EXISTS agent_message_threads (
           thread_id TEXT PRIMARY KEY NOT NULL,
           messages INTEGER NOT NULL CHECK(messages >= 0),
           updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
         );
         INSERT OR IGNORE INTO agent_message_threads(thread_id, messages, updated_at_ms)
           SELECT thread_id, COUNT(*), MAX(created_at_ms) FROM agent_messages GROUP BY thread_id;",
    )?;
    let existing: Option<String> = transaction
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'agent_message_deliveries'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    match existing {
        None => transaction.execute_batch(&format!("CREATE TABLE {DELIVERIES_TABLE};"))?,
        Some(sql) if !sql.contains("'held'") => rebuild_deliveries(transaction)?,
        Some(_) => {}
    }
    transaction.execute_batch(
        "CREATE INDEX IF NOT EXISTS agent_message_deliveries_recipient
           ON agent_message_deliveries(recipient, state);",
    )?;
    Ok(())
}

/// Copy a four-state delivery table into the current one. A row's
/// `created_at_ms` and `queued_at_ms` are its message's creation (every old
/// delivery started queued); a delivered or acknowledged row's own time is
/// its last update.
fn rebuild_deliveries(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(&format!(
        "DROP INDEX IF EXISTS agent_message_deliveries_recipient;
         ALTER TABLE agent_message_deliveries RENAME TO agent_message_deliveries_v1;
         CREATE TABLE {DELIVERIES_TABLE};
         INSERT INTO agent_message_deliveries(
           message_id, recipient, position, state, attempts, updated_at_ms, via, error,
           created_at_ms, queued_at_ms, delivered_at_ms, acknowledged_at_ms
         )
         SELECT d.message_id, d.recipient, d.position, d.state, d.attempts, d.updated_at_ms,
                d.via, d.error,
                COALESCE(m.created_at_ms, d.updated_at_ms),
                COALESCE(m.created_at_ms, d.updated_at_ms),
                CASE WHEN d.state = 'delivered' THEN d.updated_at_ms END,
                CASE WHEN d.state = 'acknowledged' THEN d.updated_at_ms END
         FROM agent_message_deliveries_v1 AS d
         LEFT JOIN agent_messages AS m ON m.message_id = d.message_id;
         DROP TABLE agent_message_deliveries_v1;"
    ))?;
    Ok(())
}
