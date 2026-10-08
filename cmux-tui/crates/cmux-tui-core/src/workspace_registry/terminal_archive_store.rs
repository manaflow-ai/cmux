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

/// Invisible format characters (bidi controls, zero-width marks) that could
/// make the marker line read differently from the program name.
fn is_format(character: char) -> bool {
    matches!(
        character,
        '\u{061C}' | '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}' | '\u{2060}'..='\u{2069}' | '\u{FEFF}'
    )
}

/// Record that the close of `terminal_id` (incarnation `generation`)
/// stopped `program`; `None` (an idle shell) removes an older stop. A later
/// stop of the same terminal replaces the row.
pub(crate) fn record_stop(
    transaction: &Transaction<'_>,
    terminal_id: &str,
    generation: &str,
    program: Option<&str>,
    now_ms: u64,
) -> anyhow::Result<()> {
    let Some(program) = program.and_then(clean_program) else {
        transaction
            .execute("DELETE FROM terminal_archive_stops WHERE terminal_id = ?1", [terminal_id])?;
        return Ok(());
    };
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
    /// The incarnation and program the close of public terminal
    /// `terminal_id` stopped.
    pub(crate) fn terminal_archive_stop(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<(String, String)>> {
        Ok(self
            .connection
            .query_row(
                "SELECT generation, program FROM terminal_archive_stops WHERE terminal_id = ?1",
                [terminal_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?)
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
mod tests {
    use super::*;

    #[test]
    fn a_program_name_keeps_no_control_characters_and_is_bounded() {
        assert_eq!(clean_program("sl\u{1b}eep").as_deref(), Some("sleep"));
        assert_eq!(clean_program("\u{7}"), None);
        assert_eq!(clean_program("ab\u{202E}c").as_deref(), Some("abc"));
        let long = "é".repeat(200);
        let clean = clean_program(&long).unwrap_or_default();
        assert!(clean.len() <= MAX_PROGRAM_BYTES && clean.chars().all(|c| c == 'é'));
    }
}
