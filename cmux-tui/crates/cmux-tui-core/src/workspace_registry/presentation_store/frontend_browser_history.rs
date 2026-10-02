//! Opaque per-tab session history of frontend-rendered browsers
//! (`frontend-browser-history-v1`): back/forward entries and scroll a
//! frontend restores across a relaunch. The daemon only checks that it is a
//! bounded JSON object. It is not presentation state: it appends no journal
//! record and never reaches the presentation snapshot, tree snapshots, or
//! deltas. A row lives as long as its `frontend_browser_tabs` row, which a
//! closed tab keeps (its tombstoned browser no longer resolves to a surface).

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
        let tx = self.connection.transaction()?;
        anyhow::ensure!(
            read_frontend_browser(&tx, browser_id)?.is_some(),
            "browser {browser_id} is not frontend-rendered"
        );
        match history {
            Some(history) => {
                tx.execute(
                    "INSERT INTO frontend_browser_history(browser_id, history) VALUES(?1, ?2)
                     ON CONFLICT(browser_id) DO UPDATE SET history = excluded.history",
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
            .query_row(
                "SELECT history FROM frontend_browser_history WHERE browser_id = ?1",
                [browser_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?)
    }

    /// Forget a frontend browser whose tab creation failed.
    pub fn delete_frontend_browser(&mut self, browser_id: &str) -> anyhow::Result<()> {
        validate_browser_public_id(browser_id)?;
        self.connection
            .execute("DELETE FROM frontend_browser_tabs WHERE browser_id = ?1", [browser_id])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workspace_registry::session_storage_component;

    fn temp_root(label: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("cmux-registry-{label}-{}", new_uuid_v4()))
    }

    const FRONTEND_BROWSER: &str = "browser_0123456789abcdef0123456789abcdef";

    fn put_test_frontend_browser(registry: &mut WorkspaceRegistry) {
        registry
            .put_frontend_browser(
                FRONTEND_BROWSER,
                &FrontendBrowserRecord {
                    engine: "webkit".into(),
                    url: "https://example.com".into(),
                    title: None,
                    favicon_url: None,
                    profile_id: None,
                },
            )
            .unwrap();
    }

    fn journal_record_count(registry: &WorkspaceRegistry) -> i64 {
        registry
            .connection
            .query_row("SELECT COUNT(*) FROM session_journal", [], |row| row.get(0))
            .unwrap()
    }

    /// Frontend browser session history is an opaque bounded JSON object kept
    /// outside the journal.
    #[test]
    fn frontend_browser_history_round_trips_outside_the_journal() {
        let root = temp_root("frontend-browser-history");
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        // Only a frontend-rendered browser has history.
        let error =
            registry.set_frontend_browser_history(FRONTEND_BROWSER, Some("{}")).unwrap_err();
        assert!(error.to_string().contains("is not frontend-rendered"));
        assert!(registry.set_frontend_browser_history("browser_nothex", Some("{}")).is_err());
        put_test_frontend_browser(&mut registry);
        assert_eq!(registry.frontend_browser_history(FRONTEND_BROWSER).unwrap(), None);

        let journal = journal_record_count(&registry);
        let history = r#"{"entries":[{"url":"https://example.com"}],"index":0}"#;
        registry.set_frontend_browser_history(FRONTEND_BROWSER, Some(history)).unwrap();
        assert_eq!(
            registry.frontend_browser_history(FRONTEND_BROWSER).unwrap().as_deref(),
            Some(history)
        );
        let replaced = r#"{"entries":[],"index":0}"#;
        registry.set_frontend_browser_history(FRONTEND_BROWSER, Some(replaced)).unwrap();
        assert_eq!(
            registry.frontend_browser_history(FRONTEND_BROWSER).unwrap().as_deref(),
            Some(replaced)
        );
        assert_eq!(journal_record_count(&registry), journal);

        // Non-objects, invalid JSON, and oversized values leave the row alone.
        for rejected in ["[]", "\"text\"", "null", "{", ""] {
            let error = registry
                .set_frontend_browser_history(FRONTEND_BROWSER, Some(rejected))
                .unwrap_err();
            assert!(error.to_string().starts_with("bad request:"), "{rejected}: {error}");
        }
        let oversized =
            format!(r#"{{"pad":"{}"}}"#, "x".repeat(MAX_FRONTEND_BROWSER_HISTORY_BYTES));
        let error =
            registry.set_frontend_browser_history(FRONTEND_BROWSER, Some(&oversized)).unwrap_err();
        assert!(error.to_string().contains("exceeds"));
        assert_eq!(
            registry.frontend_browser_history(FRONTEND_BROWSER).unwrap().as_deref(),
            Some(replaced)
        );

        // The history survives a reopen, and `None` clears it.
        drop(registry);
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        assert_eq!(
            registry.frontend_browser_history(FRONTEND_BROWSER).unwrap().as_deref(),
            Some(replaced)
        );
        registry.set_frontend_browser_history(FRONTEND_BROWSER, None).unwrap();
        assert_eq!(registry.frontend_browser_history(FRONTEND_BROWSER).unwrap(), None);
        drop(registry);
        std::fs::remove_dir_all(root).unwrap();
    }

    /// Registries created before frontend browser history existed gain the
    /// table on open.
    #[test]
    fn registries_created_before_frontend_browser_history_gain_the_table() {
        let root = temp_root("frontend-browser-history-table-migration");
        {
            let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
            put_test_frontend_browser(&mut registry);
        }
        let session_dir = root.join(session_storage_component("session"));
        let connection = Connection::open(session_dir.join("workspace-registry.sqlite3")).unwrap();
        connection.execute_batch("DROP TABLE frontend_browser_history;").unwrap();
        drop(connection);

        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        assert_eq!(registry.frontend_browser_history(FRONTEND_BROWSER).unwrap(), None);
        registry.set_frontend_browser_history(FRONTEND_BROWSER, Some("{}")).unwrap();
        assert_eq!(
            registry.frontend_browser_history(FRONTEND_BROWSER).unwrap().as_deref(),
            Some("{}")
        );
        drop(registry);
        std::fs::remove_dir_all(root).unwrap();
    }
}
