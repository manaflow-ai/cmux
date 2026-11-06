//! The Import from Conductor ledger's table: one row holding the ledger
//! ([`cmux_conductor_import::ledger::Ledger`]) as JSON, in the personal
//! state store so it follows the person's other state and commits with the
//! mutation that changed it.

use cmux_conductor_import::ledger::{Ledger, Load};
use rusqlite::{Connection, OptionalExtension, Transaction};

/// The ledger row's key: there is one ledger per person.
const ROW: i64 = 1;

pub(crate) fn create_conductor_import_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS conductor_import_ledger (
           id INTEGER PRIMARY KEY NOT NULL CHECK(id = 1),
           ledger_json TEXT NOT NULL
         );",
    )?;
    Ok(())
}

/// The stored ledger: none before the first import, and a newer build's or
/// a damaged one as it is, never read past.
pub(crate) fn load(connection: &Connection) -> anyhow::Result<Load> {
    let json = connection
        .query_row("SELECT ledger_json FROM conductor_import_ledger WHERE id = ?1", [ROW], |row| {
            row.get::<_, String>(0)
        })
        .optional()?;
    Ok(json.map_or(Load::None, |json| Ledger::decode(json.as_bytes())))
}

pub(crate) fn save(transaction: &Transaction<'_>, ledger: &Ledger) -> anyhow::Result<()> {
    let json = serde_json::to_string(ledger)?;
    transaction.execute(
        "INSERT INTO conductor_import_ledger(id, ledger_json) VALUES(?1, ?2)
         ON CONFLICT(id) DO UPDATE SET ledger_json = excluded.ledger_json",
        rusqlite::params![ROW, json],
    )?;
    Ok(())
}
