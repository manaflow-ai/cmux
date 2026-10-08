//! What a close stopped in an archived terminal (ARCHIVE-1, cx-gzh.4.1).
//!
//! A close that ends a terminal which still runs a program archives it
//! first (`mux/terminal_archive.rs`): its screen becomes the terminal's exit
//! snapshot (`terminal_exit_snapshots`) and the program the close stops is
//! one row here, so Reopen Closed shows the screen and names the program.
//!
//! One row per public terminal id: the incarnation that was stopped, the
//! program's basename (never its arguments, which can carry secrets) and the
//! time. A terminal whose shell was idle gets no row. Rows are additive and
//! small; they live as long as the closed history can reopen the terminal
//! (ARCHIVE-1: forever), like the exit snapshot they describe.

use rusqlite::{OptionalExtension, Transaction, params};

use super::WorkspaceRegistry;

pub(super) fn create_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS terminal_archive_stops (
           terminal_id TEXT PRIMARY KEY NOT NULL,
           generation TEXT NOT NULL,
           program TEXT NOT NULL,
           stopped_at_ms INTEGER NOT NULL
         );",
    )?;
    Ok(())
}

/// Longest stored program name, in bytes (cut at a character boundary).
const MAX_PROGRAM_BYTES: usize = 255;

/// `program` without control characters, at most [`MAX_PROGRAM_BYTES`].
fn clean_program(program: &str) -> Option<String> {
    let mut clean = String::new();
    for character in program.chars().filter(|character| !character.is_control()) {
        if clean.len() + character.len_utf8() > MAX_PROGRAM_BYTES {
            break;
        }
        clean.push(character);
    }
    (!clean.is_empty()).then_some(clean)
}

/// Record that the close of `terminal_id` (incarnation `generation`)
/// stopped `program`. A later stop of the same terminal replaces the row.
pub(crate) fn record_stop(
    transaction: &Transaction<'_>,
    terminal_id: &str,
    generation: &str,
    program: &str,
    now_ms: u64,
) -> anyhow::Result<()> {
    let Some(program) = clean_program(program) else { return Ok(()) };
    transaction.execute(
        "INSERT INTO terminal_archive_stops(terminal_id, generation, program, stopped_at_ms)
         VALUES(?1, ?2, ?3, ?4)
         ON CONFLICT(terminal_id) DO UPDATE SET
           generation = excluded.generation,
           program = excluded.program,
           stopped_at_ms = excluded.stopped_at_ms",
        params![terminal_id, generation, program, i64::try_from(now_ms)?],
    )?;
    Ok(())
}

impl WorkspaceRegistry {
    /// The program the close of public terminal `terminal_id` stopped.
    pub(crate) fn terminal_archive_stop(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<String>> {
        Ok(self
            .connection
            .query_row(
                "SELECT program FROM terminal_archive_stops WHERE terminal_id = ?1",
                [terminal_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_program_name_keeps_no_control_characters_and_is_bounded() {
        assert_eq!(clean_program("sl\u{1b}eep").as_deref(), Some("sleep"));
        assert_eq!(clean_program("\u{7}"), None);
        let long = "é".repeat(200);
        let clean = clean_program(&long).unwrap_or_default();
        assert!(clean.len() <= MAX_PROGRAM_BYTES && clean.chars().all(|c| c == 'é'));
    }
}
