//! Archives of closed terminals (ARCHIVE-1, cx-gzh.4.1).
//!
//! A close that stops a running terminal stores one row here
//! (`mux/terminal_archive.rs`): the screen with its newest scrollback (VT
//! replay, gzip) and the basename of the program the close stopped (never its
//! arguments). Reopen Closed shows that screen above the new shell.
//!
//! The table is bounded and deletable, unlike the append-only journal blobs:
//! - one archive keeps at most [`ARCHIVE_MAX_SCREEN_BYTES`] of VT bytes (the
//!   capture drops the oldest scrollback first);
//! - at most [`MAX_ARCHIVES`] rows; a new archive deletes the oldest beyond
//!   that, and its reopened tab starts without the old screen;
//! - triggers on `closed_groups` delete an archive once no closed-history
//!   group names its terminal (the group was reopened, consumed or deleted).
//!
//! The screen holds whatever the terminal printed, so a printed secret stays
//! until one of those three removes the row.

use std::io::{Read, Write};

use anyhow::Context;
use flate2::Compression;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use rusqlite::{OptionalExtension, Transaction, params};

use super::WorkspaceRegistry;

/// Largest VT replay one archive keeps, uncompressed.
pub(crate) const ARCHIVE_MAX_SCREEN_BYTES: usize = 1024 * 1024;
/// Most archives kept; the oldest go first.
pub(crate) const MAX_ARCHIVES: usize = 100;
/// Longest stored program name, in bytes (cut at a character boundary).
const MAX_PROGRAM_BYTES: usize = 255;

/// Creates the table and the triggers that drop an archive with the last
/// closed-history group that names its terminal. Runs after `closed_groups`
/// exists. An older daemon ignores the table; its triggers keep working
/// there, since they only read `closed_groups` and this table.
pub(crate) fn create_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    const ORPHANS: &str = "DELETE FROM terminal_archives
           WHERE instr(OLD.record_json, '\"terminal_id\":\"' || terminal_archives.terminal_id || '\"') > 0
             AND NOT EXISTS (
               SELECT 1 FROM closed_groups AS g
               WHERE instr(g.record_json, '\"terminal_id\":\"' || terminal_archives.terminal_id || '\"') > 0
             );";
    transaction.execute_batch(&format!(
        "CREATE TABLE IF NOT EXISTS terminal_archives (
           terminal_id TEXT PRIMARY KEY NOT NULL,
           generation TEXT NOT NULL,
           program TEXT,
           cols INTEGER NOT NULL CHECK(cols > 0),
           rows INTEGER NOT NULL CHECK(rows > 0),
           screen BLOB,
           screen_bytes INTEGER NOT NULL CHECK(screen_bytes >= 0),
           created_at_ms INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS terminal_archives_by_age
           ON terminal_archives(created_at_ms);
         CREATE TRIGGER IF NOT EXISTS closed_groups_delete_drops_archives
           AFTER DELETE ON closed_groups
         BEGIN {ORPHANS} END;
         CREATE TRIGGER IF NOT EXISTS closed_groups_update_drops_archives
           AFTER UPDATE OF record_json ON closed_groups
         BEGIN {ORPHANS} END;"
    ))?;
    Ok(())
}

/// One archive to store.
pub(crate) struct ArchiveRow<'a> {
    pub terminal_id: &'a str,
    pub generation: &'a str,
    pub program: Option<&'a str>,
    pub cols: u16,
    pub rows: u16,
    /// VT replay, at most [`ARCHIVE_MAX_SCREEN_BYTES`].
    pub screen: Option<&'a [u8]>,
}

/// A stored archive, as reopen reads it.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct StoredArchive {
    pub program: Option<String>,
    pub cols: u16,
    pub rows: u16,
    pub screen: Option<Vec<u8>>,
}

/// Invisible format characters (bidi controls, zero-width marks) that could
/// make the marker line read differently from the program name.
fn is_format(character: char) -> bool {
    matches!(
        character,
        '\u{061C}' | '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2060}'..='\u{2069}' | '\u{FEFF}'
    )
}

/// `program` without control or format characters, at most
/// [`MAX_PROGRAM_BYTES`].
fn clean_program(program: &str) -> Option<String> {
    let mut clean = String::new();
    for character in
        program.chars().filter(|character| !character.is_control() && !is_format(*character))
    {
        if clean.len() + character.len_utf8() > MAX_PROGRAM_BYTES {
            break;
        }
        clean.push(character);
    }
    (!clean.is_empty()).then_some(clean)
}

fn gzip(bytes: &[u8]) -> anyhow::Result<Vec<u8>> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(bytes)?;
    Ok(encoder.finish()?)
}

fn gunzip(bytes: &[u8]) -> anyhow::Result<Vec<u8>> {
    let limit = u64::try_from(ARCHIVE_MAX_SCREEN_BYTES)?.saturating_add(1);
    let mut out = Vec::new();
    GzDecoder::new(bytes).take(limit).read_to_end(&mut out).context("decompress archive")?;
    anyhow::ensure!(out.len() <= ARCHIVE_MAX_SCREEN_BYTES, "archive exceeds its size limit");
    Ok(out)
}

impl WorkspaceRegistry {
    /// Store `archives` in one transaction (a later archive of the same
    /// terminal replaces its row), then keep only the newest
    /// [`MAX_ARCHIVES`].
    pub(crate) fn put_terminal_archives(
        &mut self,
        archives: &[ArchiveRow<'_>],
        now_ms: u64,
    ) -> anyhow::Result<()> {
        if archives.is_empty() {
            return Ok(());
        }
        let tx = self.connection.transaction()?;
        for archive in archives {
            let screen = archive
                .screen
                .filter(|screen| !screen.is_empty() && screen.len() <= ARCHIVE_MAX_SCREEN_BYTES);
            tx.execute(
                "INSERT INTO terminal_archives(
                   terminal_id, generation, program, cols, rows, screen, screen_bytes,
                   created_at_ms
                 ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(terminal_id) DO UPDATE SET
                   generation = excluded.generation, program = excluded.program,
                   cols = excluded.cols, rows = excluded.rows, screen = excluded.screen,
                   screen_bytes = excluded.screen_bytes, created_at_ms = excluded.created_at_ms",
                params![
                    archive.terminal_id,
                    archive.generation,
                    archive.program.and_then(clean_program),
                    i64::from(archive.cols.max(1)),
                    i64::from(archive.rows.max(1)),
                    screen.map(gzip).transpose()?,
                    i64::try_from(screen.map_or(0, <[u8]>::len))?,
                    i64::try_from(now_ms)?,
                ],
            )?;
        }
        tx.execute(
            "DELETE FROM terminal_archives WHERE terminal_id NOT IN (
               SELECT terminal_id FROM terminal_archives
               ORDER BY created_at_ms DESC, rowid DESC LIMIT ?1
             )",
            [i64::try_from(MAX_ARCHIVES)?],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// The archive of public terminal `terminal_id`.
    pub(crate) fn terminal_archive(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<StoredArchive>> {
        let row = self
            .connection
            .query_row(
                "SELECT program, cols, rows, screen FROM terminal_archives WHERE terminal_id = ?1",
                [terminal_id],
                |row| {
                    Ok((
                        row.get::<_, Option<String>>(0)?,
                        row.get::<_, i64>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, Option<Vec<u8>>>(3)?,
                    ))
                },
            )
            .optional()?;
        let Some((program, cols, rows, screen)) = row else { return Ok(None) };
        Ok(Some(StoredArchive {
            program,
            cols: u16::try_from(cols).unwrap_or(u16::MAX),
            rows: u16::try_from(rows).unwrap_or(u16::MAX),
            screen: screen.as_deref().map(gunzip).transpose()?,
        }))
    }

    /// Whether a closed-history group can reopen public terminal
    /// `terminal_id` (its tab record names it).
    pub(crate) fn closed_history_mentions_terminal(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<bool> {
        let needle = format!("\"terminal_id\":\"{terminal_id}\"");
        Ok(self
            .connection
            .query_row(
                "SELECT 1 FROM closed_groups WHERE instr(record_json, ?1) > 0 LIMIT 1",
                [needle],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }
}

#[cfg(test)]
#[path = "terminal_archive_store_tests.rs"]
mod tests;
