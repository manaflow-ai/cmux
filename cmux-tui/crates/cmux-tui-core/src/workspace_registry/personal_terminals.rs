//! Per-terminal themes of the home session (`personal-terminals-v1`,
//! plans/cmux-next/data-model.md section 6): the own theme of a terminal on
//! any session, keyed by `{session_id, terminal_key}`. The terminal key is
//! the terminal's id on its session (its tab id when it has none). Remote
//! keys cannot be checked against a registry, so only the shape is
//! validated. Themes are personal: they are never written to the daemon
//! that runs the terminal.

use rusqlite::{OptionalExtension, params};
use serde_json::json;

use super::WorkspaceRegistry;
use super::personal_store::{
    PersonalTerminal, commit_personal, subject, validate_session_id, validate_theme,
};

/// A terminal key of any session: 1-128 printable ASCII characters.
pub fn validate_personal_terminal_key(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.is_empty()
            && value.len() <= 128
            && value.bytes().all(|byte| byte.is_ascii_graphic()),
        "bad request: terminal key must be 1-128 printable ASCII characters"
    );
    Ok(())
}

impl WorkspaceRegistry {
    /// Set (or with `None` remove) the own theme of one terminal. Returns
    /// the stored row (`None` once removed) and whether anything changed.
    pub fn set_personal_terminal(
        &mut self,
        session: &str,
        key: &str,
        theme: Option<&str>,
    ) -> anyhow::Result<(Option<PersonalTerminal>, bool)> {
        validate_session_id(session)?;
        validate_personal_terminal_key(key)?;
        if let Some(theme) = theme {
            validate_theme(theme).map_err(|error| anyhow::anyhow!("theme: {error}"))?;
        }
        let tx = self.connection.transaction()?;
        let before: Option<String> = tx
            .query_row(
                "SELECT theme FROM personal_terminals WHERE session_id = ?1 AND terminal_key = ?2",
                params![session, key],
                |row| row.get(0),
            )
            .optional()?;
        let changed = before.as_deref() != theme;
        if changed {
            match theme {
                Some(theme) => tx.execute(
                    "INSERT INTO personal_terminals(session_id, terminal_key, theme) VALUES(?1, ?2, ?3)
                     ON CONFLICT(session_id, terminal_key) DO UPDATE SET theme = excluded.theme",
                    params![session, key, theme],
                )?,
                None => tx.execute(
                    "DELETE FROM personal_terminals WHERE session_id = ?1 AND terminal_key = ?2",
                    params![session, key],
                )?,
            };
            commit_personal(
                &tx,
                "personal.terminal.updated",
                vec![subject("terminal", &format!("{session}/{key}"))],
                &json!({"session_id": session, "terminal_key": key, "theme": theme}),
            )?;
        }
        tx.commit()?;
        let row = theme.map(|theme| PersonalTerminal {
            session_id: session.to_string(),
            terminal_key: key.to_string(),
            theme: theme.to_string(),
        });
        Ok((row, changed))
    }
}
