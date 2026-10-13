//! cmux-tui refuses a write to a retired cmux.json key as removed, as the app does. The schema
//! export leaves retired keys out, so `RETIRED_KEYS` mirrors the app's table by hand; a key the
//! app retired and this table missed has no row and no refusal here, so `settings set` would
//! write a value nothing reads.

use cmux_config::schema::RETIRED_KEYS;
use std::collections::BTreeMap;

const SWIFT: &str = include_str!(
    "../../../../Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Schema/SettingsSchema+Retired.swift"
);

/// The `"key": "reason",` entries of the app's `retiredKeys` literal, unescaped.
fn app_retired_keys() -> BTreeMap<String, String> {
    let start = SWIFT.find("retiredKeys: [String: String] = [").expect("retiredKeys literal");
    let body = &SWIFT[start..];
    let body = &body[..body.find("\n    ]").expect("end of retiredKeys literal")];
    let mut keys = BTreeMap::new();
    for line in body.lines().map(str::trim) {
        let Some(entry) = line.strip_prefix('"').and_then(|l| l.strip_suffix("\",")) else {
            continue;
        };
        let (key, reason) = entry.split_once("\": \"").expect("\"key\": \"reason\"");
        keys.insert(key.to_string(), reason.replace("\\\"", "\""));
    }
    assert!(!keys.is_empty(), "the app retires no keys");
    keys
}

#[test]
fn every_key_the_app_retired_is_refused_here_with_its_reason() {
    let here: BTreeMap<String, String> =
        RETIRED_KEYS.iter().map(|(key, reason)| (key.to_string(), reason.to_string())).collect();
    assert_eq!(here, app_retired_keys());
}
