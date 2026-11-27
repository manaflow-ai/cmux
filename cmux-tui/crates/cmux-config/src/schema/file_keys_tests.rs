use super::*;

fn path(dotted: &str) -> Vec<String> {
    dotted.split('.').map(str::to_owned).collect()
}

#[test]
fn a_key_a_tool_reads_and_everything_under_it_is_owned() {
    assert!(file_key(&path("chief.turnHooks")).is_some());
    assert!(file_key(&path("chief.turnHooks.0")).is_some());
    assert!(file_key(&path("shortcuts.bindings.palette")).is_some());
    assert!(file_key(&path("chief")).is_none(), "the section is not owned, only the key");
    assert!(file_key(&path("chief.turnHooksX")).is_none());
    // The bridge's two keys are listed exactly in cmux-config's schema, so a typo under it
    // is still named.
    assert!(file_key(&path("agents.desktopBridge.entrypoint")).is_none());
}

#[test]
fn the_table_parses_and_is_not_empty() {
    assert!(serde_json::from_str::<FileKeys>(EMBEDDED).is_ok());
    assert!(!file_keys().is_empty());
}

#[test]
fn no_entry_is_a_settings_row_or_a_retired_key() {
    let schema = crate::Schema::embedded();
    for entry in file_keys() {
        let dotted = entry.path.join(".");
        assert!(
            schema.row_at(&entry.path).is_none(),
            "{dotted} is a row: drop it from file-keys.json"
        );
        assert!(super::super::retired_reason(&entry.path).is_none(), "{dotted} is retired");
        assert!(!entry.reader.trim().is_empty(), "{dotted} names no reader");
    }
}
