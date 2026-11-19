//! Derived adoption state. The log remains authoritative: forks, changed inputs, an unreadable
//! checkpoint, and a checkpoint whose final record changed all reconstruct from the log.

use super::*;
use crate::store::AdoptionPart;
use serde::{Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};

#[derive(serde::Serialize, serde::Deserialize)]
struct Point<T> {
    version: u32,
    seq: u64,
    context: Value,
    digest: Vec<u8>,
    state: T,
}

impl Hub {
    pub(in crate::hub) fn adoption_context(&self, session: &Session, incarnation: &str) -> Value {
        let meta = session.meta();
        json!([
            incarnation,
            meta.agent_session_id,
            meta.retired_agent_session_ids,
            self.remote_claude(session),
            super::super::remote_sandbox::profile_id(),
            crate::agent::REMOTE_ENV_POLICY_ID
        ])
    }

    fn adoption_record_digest(&self, session: &Session, seq: u64) -> Option<Vec<u8>> {
        if seq == 0 {
            return None;
        }
        let mut found = None;
        self.store
            .scan_back(&session.id, seq - 1, seq.checked_add(1)?, &|_, _| false, &mut |record| {
                if record.seq == seq {
                    found = serde_json::to_vec(&record)
                        .ok()
                        .map(|bytes| Sha256::digest(bytes).to_vec());
                }
                false
            })
            .ok()?;
        found
    }

    pub(in crate::hub) fn read_adoption_point<T: DeserializeOwned>(
        &self,
        session: &Session,
        part: AdoptionPart,
        context: &Value,
    ) -> Option<(u64, T)> {
        if session.meta().fork_seq.is_some() {
            return None;
        }
        let point: Point<T> =
            serde_json::from_slice(&self.store.adoption_point(&session.id, part)?).ok()?;
        if point.version != 1
            || point.context != *context
            || point.seq > self.settled_seq(session)
            || self.adoption_record_digest(session, point.seq)? != point.digest
        {
            return None;
        }
        Some((point.seq, point.state))
    }

    pub(in crate::hub) fn save_adoption_point<T: Serialize>(
        &self,
        session: &Session,
        part: AdoptionPart,
        context: Value,
        seq: u64,
        state: &T,
    ) {
        if session.meta().fork_seq.is_some() {
            return;
        }
        let Some(digest) = self.adoption_record_digest(session, seq) else { return };
        let point = Point { version: 1, seq, context, digest, state };
        let Ok(bytes) = serde_json::to_vec(&point) else { return };
        if let Err(error) = self.store.save_adoption_point(&session.id, part, &bytes) {
            tracing::debug!(session = %session.id, "adoption point not saved: {error:#}");
        }
    }
}
