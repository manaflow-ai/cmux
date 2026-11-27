//! The detector for a gated `_acpmux/sessions` field sent past its capability check. An older
//! acpmux ignores a param it does not know and answers the whole list, never an error: a filter
//! sent without the check reads every peer's sessions (31 MB on a Mac that mirrors ~10,000) and
//! the caller takes them for the narrowed list. Every sender goes through
//! `agent_session_list_gate.rs`; a gated field's name as a string anywhere else in this crate's
//! sources (tests aside) is a request built past that check.

use std::path::{Path, PathBuf};

/// The `_acpmux/sessions` fields a capability serves (acpmux `capabilities.rs`:
/// `session-list-filters-v1` and `session-list-pending-v1`).
pub(super) const GATED_FIELDS: &[&str] = &["localOnly", "excludeStatus", "orderBy", "pendingOnly"];
/// The one file that may name them: the gate.
const GATE: &str = "agent_session_list_gate.rs";

fn sources(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap_or_else(|e| panic!("{}: {e}", dir.display())) {
        let path = entry.unwrap().path();
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_owned();
        if path.is_dir() {
            if name != "tests" {
                sources(&path, out);
            }
        } else if name.ends_with(".rs")
            && !name.ends_with("_tests.rs")
            && name != "tests.rs"
            && name != GATE
        {
            out.push(path);
        }
    }
}

#[test]
fn no_gated_session_list_field_is_sent_outside_the_gate() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let mut files = Vec::new();
    sources(&root, &mut files);
    assert!(files.len() > 100, "the crate's sources were read: {}", files.len());
    let mut found = Vec::new();
    for path in files {
        let text = std::fs::read_to_string(&path).unwrap();
        for (number, line) in text.lines().enumerate() {
            for field in GATED_FIELDS {
                if line.contains(&format!("\"{field}\"")) {
                    let shown = path.strip_prefix(&root).unwrap_or(&path).display();
                    found.push(format!("{shown}:{}: {}", number + 1, line.trim()));
                }
            }
        }
    }
    assert!(
        found.is_empty(),
        "a gated _acpmux/sessions field sent without the capability check; build the request \
         with agent_session_list_gate (SessionListFilter) instead:\n{}",
        found.join("\n")
    );
}
