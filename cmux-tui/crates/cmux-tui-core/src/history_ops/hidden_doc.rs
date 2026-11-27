//! The hides of journal history (`HiddenHistory`), stored where the Swift app
//! kept them: the home session's personal frontend projection
//! `cmux-next/personal/history.hidden`, schema 1. The history module is its
//! only writer from H3 on. Each write is compare-and-swap; a conflict (an
//! older app still writing) re-reads, merges both documents and retries, so
//! no clear is lost.

use cmux_history::HiddenHistory;
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::Mux;
use crate::workspace_registry::{Actor, WorkspaceMutation};

pub(super) const FRONTEND: &str = "cmux-next";
pub(super) const SCOPE: &str = "personal";
pub(super) const SUBJECT: &str = "history.hidden";
const SCHEMA_VERSION: u32 = 1;
const ORIGIN: &str = "cmux-history";
const MAX_ATTEMPTS: usize = 4;

/// The stored document and its projection revision (0: none yet). A document
/// of another schema, or one that does not decode, reads as empty.
pub(super) fn load(mux: &Mux) -> anyhow::Result<(HiddenHistory, u64)> {
    let Some(stored) = mux.get_frontend_projection(FRONTEND, SCOPE, SUBJECT)? else {
        return Ok((HiddenHistory::new(), 0));
    };
    let document = if stored.schema_version == SCHEMA_VERSION && !stored.projection.is_null() {
        serde_json::from_value(stored.projection).unwrap_or_default()
    } else {
        HiddenHistory::new()
    };
    Ok((document, stored.projection_revision))
}

/// Applies `change` to the stored document and writes it back. `key` is the
/// request's idempotency key; it names the projection mutation together with
/// the revision it was based on, so a retried request never reuses a
/// mutation id for a different document.
pub(super) fn change(
    mux: &Mux,
    key: &str,
    actor: &Actor,
    change: impl Fn(&mut HiddenHistory),
) -> anyhow::Result<()> {
    let digest = Sha256::digest(key.as_bytes());
    let key_hash: String = digest[..12].iter().map(|byte| format!("{byte:02x}")).collect();
    let mut last_error = None;
    for _ in 0..MAX_ATTEMPTS {
        let (mut document, revision) = load(mux)?;
        change(&mut document);
        let mutation = WorkspaceMutation::new(
            format!("history-{revision}-{key_hash}"),
            ORIGIN,
            actor.clone(),
        )?;
        let value: Value = serde_json::to_value(&document)?;
        let expected = Some(revision);
        match mux.put_frontend_projection(
            &mutation,
            FRONTEND,
            SCOPE,
            SUBJECT,
            SCHEMA_VERSION,
            expected,
            &value,
        ) {
            Ok(_) => return Ok(()),
            Err(error) if error.to_string().contains("projection revision conflict") => {
                last_error = Some(error);
            }
            Err(error) => return Err(error),
        }
    }
    Err(last_error.unwrap_or_else(|| anyhow::anyhow!("history.hidden write did not settle")))
}
