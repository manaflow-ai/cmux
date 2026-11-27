//! Warms the index pages that recording a terminal's end writes, while the
//! daemon is still starting.
//!
//! Lawrence 2026-10-30: after a reboot every terminal host is gone, and the
//! startup adoption records each terminal's end before the daemon answers
//! anyone (`terminal.adopt_hosts`, 0.8-1.5 s for 462 terminals on a 41.6 GB
//! registry). 60% of that was cold page reads: each end appends a journal
//! record whose subjects (the terminal, its tabs, panes, screens and
//! workspaces) go into `journal_subject_index_by_subject_sequence`, keyed by
//! random public ids, so every insert lands on a leaf no earlier step read.
//!
//! A background thread started right after the registry opens reads those
//! leaves on read-only connections of its own, in parallel, while restore
//! runs. It changes nothing: the pages land in the OS page cache, and the
//! adoption's inserts find them there. A failure is ignored. The set is
//! every terminal that is neither exited nor tombstoned, since which hosts
//! are gone is known only during adoption; when they are all alive the
//! reads are wasted, a few thousand small reads on a background thread.

use std::path::{Path, PathBuf};

use rusqlite::Connection;

use super::open_registry_database_read_only;

/// Reader threads: an SSD serves random reads in parallel; 316 ms serial
/// became about 160 ms with 16 on the nightly registry, and the reads also
/// overlap the restore.
const PREFETCH_THREADS: usize = 8;

/// One index probe: a journal subject `(kind, id)`, or a terminal's event log
/// (`("terminal_events", terminal_id)`).
pub(crate) type PrefetchKey = (String, String);

/// The journal subjects an end of each live terminal appends, and each live
/// terminal's event-log key: the pages its end record writes.
pub(crate) fn terminal_end_prefetch_keys(
    connection: &Connection,
) -> anyhow::Result<Vec<PrefetchKey>> {
    let mut statement = connection.prepare(
        "WITH live(terminal_id, public_id) AS (
           SELECT host.terminal_id, terminal.public_id
           FROM terminal_hosts AS host
           JOIN resource_terminals AS terminal
             ON terminal.terminal_id = host.terminal_id AND terminal.deleted_revision IS NULL
           WHERE host.lifecycle NOT IN ('exited', 'tombstoned')
         ),
         paths(terminal_id, terminal, tab, pane, screen, workspace) AS (
           SELECT live.terminal_id, live.public_id, tab.public_id, pane.public_id,
                  screen.public_id, screen.workspace_id
           FROM live
           LEFT JOIN resource_tabs AS tab
             ON tab.content_id = live.public_id AND tab.deleted_revision IS NULL
           LEFT JOIN resource_panes AS pane ON pane.public_id = tab.pane_id
           LEFT JOIN resource_screens AS screen ON screen.public_id = pane.screen_id
         )
         SELECT 'terminal', terminal FROM paths
         UNION SELECT 'tab', tab FROM paths WHERE tab IS NOT NULL
         UNION SELECT 'pane', pane FROM paths WHERE pane IS NOT NULL
         UNION SELECT 'screen', screen FROM paths WHERE screen IS NOT NULL
         UNION SELECT 'workspace', workspace FROM paths WHERE workspace IS NOT NULL
         UNION SELECT 'terminal_events', terminal_id FROM paths",
    )?;
    let keys = statement
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(keys)
}

/// The probe of one key: it reads the leaf the key's next insert lands on.
const SUBJECT_PROBE: &str = "SELECT sequence FROM journal_subject_index WHERE kind = ?1 AND id = ?2
     ORDER BY sequence DESC LIMIT 1";
const EVENT_PROBE: &str = "SELECT revision FROM terminal_events WHERE terminal_id = ?1
     ORDER BY revision DESC LIMIT 1";

/// Read every key of `shard` on `connection`, two prepared statements.
fn probe_all(connection: &Connection, shard: &[PrefetchKey]) -> anyhow::Result<()> {
    let mut subjects = connection.prepare(SUBJECT_PROBE)?;
    let mut events = connection.prepare(EVENT_PROBE)?;
    for (kind, id) in shard {
        let mut rows = if kind == "terminal_events" {
            events.query([id])?
        } else {
            subjects.query([kind, id])?
        };
        let _ = rows.next()?;
    }
    Ok(())
}

/// Warm the pages of [`terminal_end_prefetch_keys`] on `PREFETCH_THREADS`
/// read-only connections. Returns the keys read.
pub(crate) fn prefetch_terminal_end_pages(database: &Path) -> anyhow::Result<usize> {
    let keys = terminal_end_prefetch_keys(&open_registry_database_read_only(database)?)?;
    let count = keys.len();
    let mut shards = vec![Vec::new(); PREFETCH_THREADS];
    for (index, key) in keys.into_iter().enumerate() {
        if let Some(shard) = shards.get_mut(index % PREFETCH_THREADS) {
            shard.push(key);
        }
    }
    std::thread::scope(|scope| {
        for shard in shards.into_iter().filter(|shard| !shard.is_empty()) {
            scope.spawn(move || {
                if let Ok(connection) = open_registry_database_read_only(database) {
                    let _ = probe_all(&connection, &shard);
                }
            });
        }
    });
    Ok(count)
}

/// Start [`prefetch_terminal_end_pages`] on a detached thread. Best effort:
/// nothing waits for it and its errors are dropped.
pub(crate) fn start_terminal_end_prefetch(database: PathBuf) {
    let _ = std::thread::Builder::new().name("terminal-end-prefetch".into()).spawn(move || {
        let _ = prefetch_terminal_end_pages(&database);
    });
}
