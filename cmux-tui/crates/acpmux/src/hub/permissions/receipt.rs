//! Bounded delivery evidence, not permission authority. A claim is durable before the answer
//! is sent. `delivered` means the ACP asking task accepted the answer, not that the harness
//! executed it. A crash between send and the durable result remains `unknown`; never resend.
//! Keeps 256 attempts per session. Only terminal entries are evicted; an evicted id is unknown.
//! Like the session store, this assumes the user's on-disk data is not maliciously rewritten.

use super::*;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::Read;
use std::path::Path;

const MAX: usize = 256;
const MAX_BYTES: u64 = 512 * 1024;
const FILE: &str = "permission-delivery.json";

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Attempt {
    pub id: String,
    instance: String,
    decision_nonce: String,
    request_digest: String,
    answers_digest: String,
    #[serde(default)]
    annotations_digest: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Receipt {
    #[serde(flatten)]
    attempt: Attempt,
    session: String,
    permission: String,
    option: Option<String>,
    state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<String>,
    sequence: u64,
}

#[derive(Debug, Default)]
pub(crate) struct Ledger {
    loaded: bool,
    rows: BTreeMap<String, Receipt>,
}

fn error(reason: &str) -> RpcError {
    RpcError::new(-32000, reason).with_data(json!({"reason":reason}))
}
fn storage_error(_: impl std::fmt::Display) -> RpcError {
    error("question.delivery_unknown")
}
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id.bytes().all(|c| c.is_ascii_alphanumeric() || b"-_.:".contains(&c))
}

impl Receipt {
    #[allow(clippy::too_many_arguments)]
    pub(super) fn prepare(
        attempt: Attempt,
        session: &str,
        permission: &str,
        instance: &str,
        pending: &PendingPermission,
        option: Option<&str>,
        answers: Option<&Value>,
        annotations: Option<&Value>,
    ) -> Result<Self, RpcError> {
        if !valid_id(&attempt.id)
            || attempt.instance != instance
            || attempt.decision_nonce != pending.decision_nonce
            || attempt.request_digest
                != super::super::approvers::answers_digest(Some(&pending.request))
            || attempt.answers_digest != super::super::approvers::answers_digest(answers)
            || attempt.annotations_digest != super::super::approvers::answers_digest(annotations)
        {
            return Err(error("question.stale"));
        }
        Ok(Self {
            attempt,
            session: session.into(),
            permission: permission.into(),
            option: option.map(str::to_owned),
            state: "unknown".into(),
            reason: None,
            sequence: 0,
        })
    }
}

impl Ledger {
    fn load(&mut self, path: Option<&Path>) -> Result<(), RpcError> {
        if self.loaded {
            return Ok(());
        }
        if let Some(path) = path {
            let file = crate::home_fs::OpenOptions::new().read(true).open(path);
            match file {
                Ok(file) => {
                    let mut bytes = Vec::new();
                    file.take(MAX_BYTES + 1).read_to_end(&mut bytes).map_err(storage_error)?;
                    if bytes.len() as u64 > MAX_BYTES {
                        return Err(storage_error("too large"));
                    }
                    let rows: BTreeMap<String, Receipt> =
                        serde_json::from_slice(&bytes).map_err(storage_error)?;
                    if rows.len() > MAX
                        || rows.iter().any(|(id, r)| id != &r.attempt.id || !valid_id(id))
                    {
                        return Err(storage_error("invalid ledger"));
                    }
                    self.rows = rows;
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(storage_error(e)),
            }
        }
        self.loaded = true;
        Ok(())
    }

    fn persist(rows: &BTreeMap<String, Receipt>, path: Option<&Path>) -> Result<(), RpcError> {
        if let Some(path) = path {
            let bytes = serde_json::to_vec(rows).map_err(storage_error)?;
            if bytes.len() as u64 > MAX_BYTES {
                return Err(storage_error("too large"));
            }
            crate::config::write_atomic(path, &bytes).map_err(storage_error)?;
            // write_atomic's usual directory sync is best-effort; delivery claims require it.
            crate::home_fs::sync_dir(path.parent().ok_or_else(|| storage_error("no parent"))?)
                .map_err(storage_error)?;
        }
        Ok(())
    }

    pub(super) fn claim(&mut self, receipt: &Receipt, path: Option<&Path>) -> Result<(), RpcError> {
        self.load(path)?;
        if let Some(previous) = self.rows.get(&receipt.attempt.id) {
            return Err(error(
                if previous.attempt == receipt.attempt
                    && previous.session == receipt.session
                    && previous.permission == receipt.permission
                    && previous.option == receipt.option
                {
                    "question.delivery_claimed"
                } else {
                    "question.delivery_conflict"
                },
            ));
        }
        let mut next = self.rows.clone();
        if next.len() == MAX {
            let oldest = next
                .iter()
                .filter(|(_, r)| r.state != "unknown")
                .min_by_key(|(_, r)| r.sequence)
                .map(|(id, _)| id.clone())
                .ok_or_else(|| error("question.delivery_capacity"))?;
            next.remove(&oldest);
        }
        let mut receipt = receipt.clone();
        receipt.sequence =
            self.rows.values().map(|r| r.sequence).max().unwrap_or(0).saturating_add(1);
        next.insert(receipt.attempt.id.clone(), receipt);
        // Keep the claim in memory even if rename succeeded but directory sync failed.
        self.rows = next;
        Self::persist(&self.rows, path)
    }

    pub(super) fn finish(
        &mut self,
        id: &str,
        delivered: bool,
        path: Option<&Path>,
    ) -> Result<(), RpcError> {
        let mut next = self.rows.clone();
        let row = next.get_mut(id).ok_or_else(|| storage_error("claim missing"))?;
        row.state = if delivered { "delivered" } else { "refused" }.into();
        row.reason = (!delivered).then(|| "agent_gone".into());
        Self::persist(&next, path)?;
        self.rows = next;
        Ok(())
    }

    fn status(&mut self, id: &str, path: Option<&Path>) -> Result<Value, RpcError> {
        if !valid_id(id) {
            return Err(RpcError::invalid_params("invalid deliveryAttempt"));
        }
        self.load(path)?;
        Ok(self.rows.get(id).map_or_else(|| json!({"id":id,"state":"unknown"}), |r| json!(r)))
    }
}

impl Hub {
    pub(super) fn delivery_path(&self, session: &Session) -> Option<PathBuf> {
        // A journal-backed session may still have only an overlay: materialize its
        // metadata before writing a sibling file. This happens outside the permissions lock.
        self.store.session_dir(&session.id).map(|dir| dir.join(FILE))
    }

    /// A read cannot answer anything. Missing/expired receipts remain unknown, never success.
    pub(crate) fn permission_delivery_status(
        &self,
        session: &Session,
        id: &str,
    ) -> Result<Value, RpcError> {
        let path = self.store.session_path(&session.id).map(|dir| dir.join(FILE));
        session
            .permissions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .deliveries
            .status(id, path.as_deref())
    }
}

#[cfg(test)]
#[path = "receipt_tests.rs"]
mod tests;
