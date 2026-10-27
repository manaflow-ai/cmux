//! cmux.json keys cmux used to read and no longer does. The one list is
//! `schemas/settings/retired-keys.json` (hand-edited, cx-d5b5d), embedded
//! here; the app's Swift table is generated from the same file by
//! `scripts/cmux-next/gen-settings-sources.py`. Loading ignores a retired
//! key without a diagnostic; a write is refused as removed; a reset cleans
//! an old file.

use std::sync::OnceLock;

use serde::Deserialize;

const EMBEDDED: &str = include_str!("../../../../../schemas/settings/retired-keys.json");

#[derive(Deserialize)]
struct RetiredFile {
    retired: Vec<RetiredEntry>,
}

#[derive(Deserialize)]
struct RetiredEntry {
    key: String,
    reason: String,
}

/// Every retired dotted key and why, in the file's order.
#[allow(
    clippy::expect_used,
    reason = "INVARIANT: retired-keys.json is compiled in and the settings behavior tests parse it on every run"
)]
pub fn retired_keys() -> &'static [(String, String)] {
    static TABLE: OnceLock<Vec<(String, String)>> = OnceLock::new();
    TABLE.get_or_init(|| {
        // The file is compiled in; gen-settings-sources.py --check validates it in CI.
        // crash-allow: compiled in, and the settings behavior tests parse it on every run.
        let file: RetiredFile = serde_json::from_str(EMBEDDED).expect("retired-keys.json parses");
        file.retired.into_iter().map(|entry| (entry.key, entry.reason)).collect()
    })
}

/// The reason `path` was retired, or `None` when it is not retired.
pub fn retired_reason(path: &[String]) -> Option<&'static str> {
    let dotted = path.join(".");
    retired_keys().iter().find(|(key, _)| *key == dotted).map(|(_, reason)| reason.as_str())
}
