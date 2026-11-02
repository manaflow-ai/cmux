//! The feed's `pulled.json` (written by `nightly-next-rollback.yml` next to
//! the appcast): builds taken off the feed, why, and the build served instead.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PulledBuild {
    pub build: String,
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub pulled_at: Option<String>,
    #[serde(default)]
    pub serve: Option<String>,
}

/// The entries of a `pulled.json` body; an unreadable body or entry is
/// skipped, never fatal. An entry needs a string `build`; a missing or
/// non-string `reason` reads as empty.
pub fn decode(body: &[u8]) -> Vec<PulledBuild> {
    let Ok(serde_json::Value::Array(entries)) = serde_json::from_slice::<serde_json::Value>(body)
    else {
        return Vec::new();
    };
    entries
        .iter()
        .filter_map(|entry| {
            let entry = entry.as_object()?;
            let text =
                |key: &str| entry.get(key).and_then(serde_json::Value::as_str).map(str::to_owned);
            Some(PulledBuild {
                build: text("build")?,
                reason: text("reason").unwrap_or_default(),
                pulled_at: text("pulledAt"),
                serve: text("serve"),
            })
        })
        .collect()
}
