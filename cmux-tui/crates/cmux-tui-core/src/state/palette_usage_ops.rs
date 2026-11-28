//! `palette_usage.record`, `.import`, `.hide` and `.forget`: one reducer step on
//! the state commit path (row, replay record and one `session.events` batch
//! with a `state_upsert` of resource `palette_usage`, id `user`).
//!
//! No usage data reaches the replay record, the event journal or the
//! `state_upsert`: `record` returns only `{revision}`, `import` only
//! `{revision, imported}`, the event value is `{revision}`, and the replay
//! fingerprints hold a SHA-256 of the key and query (or of the import rows),
//! never the text. Readers fetch the history with `palette_usage.get` (a read,
//! never journaled). No `personal-changed`: the app reads after its own write.

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::json;
use sha2::{Digest, Sha256};

use crate::mux::*;
use crate::state::commit::StateEffects;
use crate::state::palette_usage::{self, Entry};
use crate::state::palette_usage_store::{self as store, ID, RESOURCE};
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit, state_upsert};

fn digest(parts: &[&str]) -> String {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update(part.len().to_le_bytes());
        hasher.update(part.as_bytes());
    }
    format!("{:x}", hasher.finalize())
}

/// The daemon's clock: every use is stamped here, never by a client.
pub(crate) fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

impl Mux {
    /// One use of palette row `key`, run for `query` ("" when the query was
    /// empty), under `mutation`'s idempotency key.
    pub(crate) fn state_palette_usage_record(
        &self,
        mutation: &WorkspaceMutation,
        key: &str,
        query: &str,
    ) -> anyhow::Result<StateCommit> {
        let fingerprint = json!({
            "operation": "palette_usage.record",
            "use": digest(&[key, &palette_usage::normalized_query(query)]),
        });
        let now = now_ms();
        self.commit_palette_usage(
            mutation,
            "palette_usage.record",
            &fingerprint,
            |current| palette_usage::record(current, key, query, now),
            |next, _| json!({"revision": next.revision.to_string()}),
        )
    }

    /// Merges a former history from `source` once (a source seen before
    /// commits nothing new).
    pub(crate) fn state_palette_usage_import(
        &self,
        mutation: &WorkspaceMutation,
        source: &str,
        entries: &[(String, Entry)],
    ) -> anyhow::Result<StateCommit> {
        let rows: Vec<String> = entries
            .iter()
            .map(|(key, entry)| format!("{key}\u{0}{}\u{0}{}", entry.score, entry.last_used_ms))
            .collect();
        let mut parts = vec![source];
        parts.extend(rows.iter().map(String::as_str));
        let fingerprint = json!({"operation": "palette_usage.import", "rows": digest(&parts)});
        let now = now_ms();
        self.commit_palette_usage(
            mutation,
            "palette_usage.import",
            &fingerprint,
            |current| palette_usage::import(current, source, entries, now),
            |next, changed| json!({"revision": next.revision.to_string(), "imported": changed}),
        )
    }

    /// Hides row `key` from the palette, or shows it again (`hidden` false).
    pub(crate) fn state_palette_usage_hide(
        &self,
        mutation: &WorkspaceMutation,
        key: &str,
        hidden: bool,
    ) -> anyhow::Result<StateCommit> {
        let flag = if hidden { "hide" } else { "show" };
        let fingerprint = json!({"operation": "palette_usage.hide", "row": digest(&[key, flag])});
        self.commit_palette_usage(
            mutation,
            "palette_usage.hide",
            &fingerprint,
            |current| palette_usage::set_hidden(current, key, hidden),
            |next, _| json!({"revision": next.revision.to_string()}),
        )
    }

    /// Reset Ranking: forgets row `key`'s uses and learned picks.
    pub(crate) fn state_palette_usage_forget(
        &self,
        mutation: &WorkspaceMutation,
        key: &str,
    ) -> anyhow::Result<StateCommit> {
        let fingerprint = json!({"operation": "palette_usage.forget", "row": digest(&[key])});
        self.commit_palette_usage(
            mutation,
            "palette_usage.forget",
            &fingerprint,
            |current| palette_usage::forget(current, key),
            |next, _| json!({"revision": next.revision.to_string()}),
        )
    }

    fn commit_palette_usage(
        &self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        step: impl FnOnce(
            &palette_usage::Document,
        ) -> Result<palette_usage::Document, palette_usage::Reject>,
        result: impl FnOnce(&palette_usage::Document, bool) -> Value,
    ) -> anyhow::Result<StateCommit> {
        self.commit_state(
            mutation,
            operation,
            fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                let current = store::document(transaction)?;
                let next = step(&current)
                    .map_err(|reject| anyhow::anyhow!("bad request: {}", reject.as_str()))?;
                let changed = next.revision != current.revision;
                let value = result(&next, changed);
                if !changed {
                    return Ok(StateChanges::new(value, Vec::new()));
                }
                store::write_document(transaction, &next)?;
                let upsert =
                    state_upsert(RESOURCE, ID, json!({"revision": next.revision.to_string()}));
                Ok(StateChanges::new(value, vec![upsert]))
            },
        )
    }
}
