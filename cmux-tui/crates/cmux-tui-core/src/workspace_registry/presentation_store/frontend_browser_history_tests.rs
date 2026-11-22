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
                owner: None,
            },
            None,
        )
        .unwrap();
}

fn journal_record_count(registry: &WorkspaceRegistry) -> i64 {
    registry
        .connection
        .get()
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
    let error = registry.set_frontend_browser_history(FRONTEND_BROWSER, Some("{}")).unwrap_err();
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
        let error =
            registry.set_frontend_browser_history(FRONTEND_BROWSER, Some(rejected)).unwrap_err();
        assert!(error.to_string().starts_with("bad request:"), "{rejected}: {error}");
    }
    let oversized = format!(r#"{{"pad":"{}"}}"#, "x".repeat(MAX_FRONTEND_BROWSER_HISTORY_BYTES));
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
    assert_eq!(registry.frontend_browser_history(FRONTEND_BROWSER).unwrap().as_deref(), Some("{}"));
    drop(registry);
    std::fs::remove_dir_all(root).unwrap();
}
