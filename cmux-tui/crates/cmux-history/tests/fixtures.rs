//! Shared JSON fixtures (tests/fixtures/*.json), written so the Swift
//! CmuxNextHistory tests can adopt the same files.

use cmux_history::{
    AgentSessionFold, EntryContext, HiddenHistory, HistoryEntry, HistoryQuery, TerminalCommandFold,
    apply,
};
use serde::Deserialize;
use serde_json::Value;

#[derive(Deserialize)]
struct FoldFile {
    cases: Vec<FoldCase>,
}

#[derive(Deserialize)]
struct FoldCase {
    name: String,
    machine: String,
    local_machine: String,
    available: bool,
    #[serde(default)]
    capacity: Option<usize>,
    #[serde(default)]
    hidden: Option<HiddenHistory>,
    batches: Vec<Vec<Value>>,
    expected_cursor: u64,
    expected_entries: Vec<HistoryEntry>,
}

#[derive(Deserialize)]
struct QueryFile {
    now_ms: i64,
    local_day_start_ms: i64,
    directories: Vec<String>,
    entries: Vec<HistoryEntry>,
    cases: Vec<QueryCase>,
}

#[derive(Deserialize)]
struct QueryCase {
    name: String,
    query: HistoryQuery,
    expected_ids: Vec<String>,
}

fn load<T: for<'de> Deserialize<'de>>(name: &str) -> T {
    let path = format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    let text = std::fs::read_to_string(&path).unwrap_or_else(|error| panic!("{path}: {error}"));
    serde_json::from_str(&text).unwrap_or_else(|error| panic!("{path}: {error}"))
}

#[test]
fn agent_fold_fixtures() {
    let file: FoldFile = load("agent_fold.json");
    assert!(!file.cases.is_empty());
    for case in file.cases {
        let mut fold = match case.capacity {
            Some(capacity) => AgentSessionFold::with_capacity(&case.machine, capacity),
            None => AgentSessionFold::new(&case.machine),
        };
        for batch in &case.batches {
            fold.apply(batch);
        }
        let context =
            EntryContext { local_machine: &case.local_machine, available: case.available };
        let entries = fold.entries(&context, &case.hidden.unwrap_or_default());
        assert_eq!(fold.cursor(), case.expected_cursor, "{}", case.name);
        assert_eq!(entries, case.expected_entries, "{}", case.name);
    }
}

#[test]
fn command_fold_fixtures() {
    let file: FoldFile = load("command_fold.json");
    assert!(!file.cases.is_empty());
    for case in file.cases {
        let mut fold = match case.capacity {
            Some(capacity) => TerminalCommandFold::with_capacity(&case.machine, capacity),
            None => TerminalCommandFold::new(&case.machine),
        };
        for batch in &case.batches {
            fold.apply(batch);
        }
        let context =
            EntryContext { local_machine: &case.local_machine, available: case.available };
        let entries = fold.entries(&context, &case.hidden.unwrap_or_default());
        assert_eq!(fold.cursor(), case.expected_cursor, "{}", case.name);
        assert_eq!(entries, case.expected_entries, "{}", case.name);
    }
}

#[test]
fn query_fixtures() {
    let file: QueryFile = load("query.json");
    assert!(!file.cases.is_empty());
    let is_directory =
        |path: &str| file.directories.iter().any(|dir| dir == path.trim_end_matches('/'));
    for case in &file.cases {
        let ids: Vec<String> =
            apply(&case.query, &file.entries, file.now_ms, file.local_day_start_ms, is_directory)
                .into_iter()
                .map(|entry| entry.id)
                .collect();
        assert_eq!(ids, case.expected_ids, "{}", case.name);
    }
}

#[test]
fn fixture_entries_round_trip_without_absent_fields() {
    let file: QueryFile = load("query.json");
    for entry in &file.entries {
        let value = serde_json::to_value(entry).unwrap();
        let object = value.as_object().unwrap();
        assert!(object.values().all(|field| !field.is_null()), "{}", entry.id);
        let back: HistoryEntry = serde_json::from_value(value).unwrap();
        assert_eq!(&back, entry);
    }
}
