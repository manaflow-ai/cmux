//! Retention, background scan and quarantine for the mutation idempotency
//! ledgers: `mutations`, `projection_mutations` and `terminal_mutations`.
//!
//! A ledger row keeps a committed mutation's result under its
//! `(origin, mutation_id)`, so a retry of that mutation replays the result
//! instead of applying it twice. Nothing else reads the ledgers. A retry
//! comes from a client that lost the reply, so it follows the original
//! closely, and a ledger only has to hold the recent past. Unbounded, they
//! grew with every write: one nightly's `projection_mutations` held 1 GB.
//!
//! - Retention keeps each ledger's newest rows by rowid, which is insertion
//!   order. The maintenance worker deletes the excess oldest first, one
//!   bounded batch at a time, so a large ledger drains over several ticks
//!   without holding the registry lock for long, and startup never pays for
//!   it. The freed pages go back to the OS at incremental vacuum's pace.
//! - The open check touches only each ledger's tail. The maintenance worker
//!   runs the full `quick_check` on a read-only connection of its own once
//!   retention has drained them, at an interval after that, and at once when
//!   a prune hits a corrupt page.
//! - A ledger the scan finds corrupt is renamed to
//!   `<ledger>_quarantined_<unix ms>` and recreated empty from its own
//!   schema. A corrupt page there would fail every commit that writes to the
//!   ledger, and its rows are only a retry cache: losing them means a retry
//!   of an earlier mutation applies again instead of replaying. The renamed
//!   table keeps the damaged rows in the file for inspection and is never
//!   checked or read again. Unlike an unreadable registry (`open_guard`), the
//!   rest of the database stays where it is.
//!
//! Quarantine restores commits, not the file. The damaged pages stay
//! allocated, so whatever reads every page still fails on them as it did
//! before: `VACUUM`, `VACUUM INTO` (compaction and session import), and an
//! incremental vacuum that reaches them. Recovering the file stays an
//! offline job.

use std::path::Path;

use rusqlite::{Connection, ErrorCode, params};

use super::resource_store::RESOURCE_MUTATION_REPLAY_CAPACITY;
use super::{WorkspaceRegistry, open_registry_database_read_only};

/// One ledger's retention bound.
pub(crate) struct MutationLedger {
    pub(crate) table: &'static str,
    /// Rows kept, newest first.
    pub(crate) capacity: usize,
    /// Rows deleted per prune call, so one call stays short.
    pub(crate) batch: usize,
}

pub(crate) const MUTATION_LEDGERS: [MutationLedger; 3] = [
    MutationLedger { table: "mutations", capacity: RESOURCE_MUTATION_REPLAY_CAPACITY, batch: 512 },
    MutationLedger {
        table: "terminal_mutations",
        capacity: RESOURCE_MUTATION_REPLAY_CAPACITY,
        batch: 512,
    },
    // A projection row written before the digest ledger holds the whole
    // projection twice (fingerprint and result, up to 1 MiB each then), so
    // this ledger keeps fewer rows and frees fewer per batch: with
    // secure_delete every freed byte is rewritten under the registry lock.
    // New rows hold a digest and a result without the body (a few hundred
    // bytes).
    MutationLedger { table: "projection_mutations", capacity: 1024, batch: 16 },
];

const QUARANTINE_INFIX: &str = "_quarantined_";

/// Whether `table` is a ledger a scan moved aside. The open check skips it.
pub(crate) fn is_quarantined_ledger(table: &str) -> bool {
    MUTATION_LEDGERS.iter().any(|ledger| {
        table.strip_prefix(ledger.table).is_some_and(|rest| rest.starts_with(QUARANTINE_INFIX))
    })
}

/// What one [`WorkspaceRegistry::prune_mutation_ledgers`] call did.
#[derive(Debug, Default)]
pub(crate) struct LedgerPrune {
    /// Rows deleted across the ledgers. Zero, with nothing corrupt, means
    /// every ledger is within its bound.
    pub(crate) deleted: usize,
    /// Ledgers whose prune hit a corrupt page.
    pub(crate) corrupt: Vec<&'static str>,
}

impl WorkspaceRegistry {
    /// Deletes up to one batch of each ledger's rows past its capacity,
    /// oldest first. A corrupt page in one ledger is reported and does not
    /// stop the others.
    pub(crate) fn prune_mutation_ledgers(&mut self) -> anyhow::Result<LedgerPrune> {
        let connection = self.connection.get();
        let mut prune = LedgerPrune::default();
        for ledger in &MUTATION_LEDGERS {
            match prune_ledger(&connection, ledger) {
                Ok(deleted) => prune.deleted += deleted,
                Err(error) if error.sqlite_error_code() == Some(ErrorCode::DatabaseCorrupt) => {
                    prune.corrupt.push(ledger.table);
                }
                Err(error) => return Err(error.into()),
            }
        }
        Ok(prune)
    }

    /// Renames a corrupt ledger aside and recreates it empty from its own
    /// schema, in one transaction. Neither step reads the table's pages.
    /// Returns the name the damaged table now has.
    pub(crate) fn quarantine_mutation_ledger(&mut self, table: &str) -> anyhow::Result<String> {
        anyhow::ensure!(
            MUTATION_LEDGERS.iter().any(|ledger| ledger.table == table),
            "not a mutation ledger: {table}"
        );
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_millis())
            .unwrap_or_default();
        let aside = format!("{table}{QUARANTINE_INFIX}{millis}");
        let connection = self.connection.get();
        let transaction = connection.unchecked_transaction()?;
        let schema: String = transaction.query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [table],
            |row| row.get(0),
        )?;
        transaction.execute_batch(&format!("ALTER TABLE {table} RENAME TO {aside}"))?;
        transaction.execute_batch(&schema)?;
        transaction.commit()?;
        Ok(aside)
    }
}

fn prune_ledger(connection: &Connection, ledger: &MutationLedger) -> rusqlite::Result<usize> {
    let table = ledger.table;
    let bound = |value: usize| i64::try_from(value).unwrap_or(i64::MAX);
    connection.execute(
        &format!(
            "DELETE FROM {table} WHERE rowid IN (
               SELECT rowid FROM {table}
               WHERE rowid <= (SELECT rowid FROM {table} ORDER BY rowid DESC LIMIT 1 OFFSET ?1)
               ORDER BY rowid
               LIMIT ?2
             )"
        ),
        params![bound(ledger.capacity), bound(ledger.batch)],
    )
}

/// The ledgers whose `quick_check` fails, each with SQLite's report. It
/// reads on a connection of its own, so the scan never holds the registry
/// lock while it walks a large ledger.
pub(crate) fn scan_mutation_ledgers(
    database: &Path,
) -> anyhow::Result<Vec<(&'static str, String)>> {
    let connection = open_registry_database_read_only(database)?;
    connection.busy_timeout(std::time::Duration::from_secs(5))?;
    let mut corrupt = Vec::new();
    for ledger in &MUTATION_LEDGERS {
        let pragma = format!("PRAGMA quick_check('{}')", ledger.table);
        match connection.query_row(&pragma, [], |row| row.get::<_, String>(0)) {
            Ok(report) if report == "ok" => {}
            Ok(report) => corrupt.push((ledger.table, report)),
            Err(error) if error.sqlite_error_code() == Some(ErrorCode::DatabaseCorrupt) => {
                corrupt.push((ledger.table, error.to_string()));
            }
            Err(error) => return Err(error.into()),
        }
    }
    Ok(corrupt)
}
