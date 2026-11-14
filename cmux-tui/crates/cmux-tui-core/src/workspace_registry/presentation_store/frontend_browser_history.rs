//! Opaque per-tab session history of frontend-rendered browsers
//! (`frontend-browser-history-v1`): back/forward entries and scroll a
//! frontend restores across a relaunch. The daemon only checks that it is a
//! bounded JSON object. It is not presentation state: it appends no journal
//! record and never reaches the presentation snapshot, tree snapshots, or
//! deltas. A row lives as long as its `frontend_browser_tabs` row: the
//! commit that closes the browser deletes both
//! (state/conversation_tabs_store.rs `delete_closed_browser_rows`).

use super::*;

/// Largest accepted frontend browser session history, in bytes of compact
/// JSON.
pub const MAX_FRONTEND_BROWSER_HISTORY_BYTES: usize = 64 * 1024;

/// Additive like every presentation table: registries created by older
/// binaries gain it on open, and an older binary ignores it.
pub(super) fn create_frontend_browser_history_schema(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS frontend_browser_history (
           browser_id TEXT PRIMARY KEY NOT NULL,
           history TEXT NOT NULL
         );",
    )?;
    Ok(())
}

/// A frontend browser session history must be a JSON object of at most
/// [`MAX_FRONTEND_BROWSER_HISTORY_BYTES`].
fn validate_frontend_browser_history(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        value.len() <= MAX_FRONTEND_BROWSER_HISTORY_BYTES,
        "bad request: history exceeds {MAX_FRONTEND_BROWSER_HISTORY_BYTES} bytes"
    );
    let parsed: Value = serde_json::from_str(value)
        .map_err(|error| anyhow::anyhow!("bad request: history is not valid JSON: {error}"))?;
    anyhow::ensure!(parsed.is_object(), "bad request: history must be a JSON object");
    Ok(())
}

impl WorkspaceRegistry {
    /// Store (`Some`) or clear (`None`) the session history of a
    /// frontend-rendered browser.
    pub fn set_frontend_browser_history(
        &mut self,
        browser_id: &str,
        history: Option<&str>,
    ) -> anyhow::Result<()> {
        validate_browser_public_id(browser_id)?;
        if let Some(history) = history {
            validate_frontend_browser_history(history)?;
        }
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        anyhow::ensure!(
            read_frontend_browser(&tx, browser_id)?.is_some(),
            "browser {browser_id} is not frontend-rendered"
        );
        match history {
            Some(history) => {
                tx.execute(
                    // A report of the history already stored writes nothing.
                    "INSERT INTO frontend_browser_history(browser_id, history) VALUES(?1, ?2)
                     ON CONFLICT(browser_id) DO UPDATE SET history = excluded.history
                     WHERE frontend_browser_history.history IS NOT excluded.history",
                    params![browser_id, history],
                )?;
            }
            None => {
                tx.execute(
                    "DELETE FROM frontend_browser_history WHERE browser_id = ?1",
                    [browser_id],
                )?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    /// The session history last stored for a frontend browser, if any.
    pub fn frontend_browser_history(&self, browser_id: &str) -> anyhow::Result<Option<String>> {
        validate_browser_public_id(browser_id)?;
        Ok(self
            .connection
            .get()
            .query_row(
                "SELECT history FROM frontend_browser_history WHERE browser_id = ?1",
                [browser_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?)
    }
}

#[cfg(test)]
mod tests;
