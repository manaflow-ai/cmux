//! The bounded in-memory resource journal (`ResourceJournal`): one commit
//! advances the revision once, with ordered deltas.

use std::collections::VecDeque;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{JOURNAL_BYTE_CAPACITY, JOURNAL_CAPACITY, ResourceError, WireDecimal};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResourceDelta {
    pub sequence: u32,
    pub event: String,
    pub data: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResourceDeltaBatch {
    pub previous_revision: WireDecimal,
    pub revision: WireDecimal,
    pub deltas: Vec<ResourceDelta>,
}

/// Bounded contiguous journal: one commit advances the revision once, with ordered deltas.
#[derive(Debug)]
pub struct ResourceJournal {
    generation: String,
    revision: u64,
    batches: VecDeque<(ResourceDeltaBatch, usize)>,
    capacity: usize,
    pub(super) byte_capacity: usize,
    retained_bytes: usize,
}

impl ResourceJournal {
    pub fn new(generation: String, revision: u64) -> Self {
        Self {
            generation,
            revision,
            batches: VecDeque::new(),
            capacity: JOURNAL_CAPACITY,
            byte_capacity: JOURNAL_BYTE_CAPACITY,
            retained_bytes: 0,
        }
    }

    pub fn generation(&self) -> &str {
        &self.generation
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn commit(&mut self, events: Vec<(String, Value)>) -> anyhow::Result<u64> {
        let previous_revision = self.revision;
        let revision = self
            .revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        let deltas = events
            .into_iter()
            .enumerate()
            .map(|(sequence, (event, data))| {
                Ok(ResourceDelta {
                    sequence: u32::try_from(sequence).map_err(|_| {
                        anyhow::anyhow!("too many deltas in one resource transaction")
                    })?,
                    event,
                    data,
                })
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        let batch = ResourceDeltaBatch {
            previous_revision: WireDecimal::new(previous_revision),
            revision: WireDecimal::new(revision),
            deltas,
        };
        let bytes = serde_json::to_vec(&batch)?.len();
        if bytes > self.byte_capacity {
            anyhow::bail!("one resource delta batch exceeds journal byte capacity");
        }
        self.revision = revision;
        self.batches.push_back((batch, bytes));
        self.retained_bytes = self.retained_bytes.saturating_add(bytes);
        while self.batches.len() > self.capacity || self.retained_bytes > self.byte_capacity {
            let Some((_, removed)) = self.batches.pop_front() else { break };
            self.retained_bytes = self.retained_bytes.saturating_sub(removed);
        }
        Ok(self.revision)
    }

    pub fn after(&self, revision: u64) -> Result<Vec<ResourceDeltaBatch>, ResourceError> {
        if revision > self.revision {
            return Err(ResourceError::new(
                "cursor.invalid",
                "resume cursor is ahead of the session revision",
                json!({
                    "requested":{
                        "generation":self.generation,
                        "revision":revision.to_string(),
                    },
                    "current":{
                        "generation":self.generation,
                        "revision":self.revision.to_string(),
                    },
                    "reason":"resume cursor is ahead of the session revision",
                }),
                false,
            ));
        }
        let oldest = self.batches.front().map_or(self.revision, |(batch, _)| batch.revision.get());
        if revision.saturating_add(1) < oldest {
            return Err(ResourceError::new(
                "cursor.gap",
                "resume cursor is no longer retained",
                json!({
                    "requested":{
                        "generation":self.generation,
                        "revision":revision.to_string(),
                    },
                    "current":{
                        "generation":self.generation,
                        "revision":self.revision.to_string(),
                    },
                    "oldest_revision":oldest.to_string(),
                }),
                true,
            ));
        }
        Ok(self
            .batches
            .iter()
            .filter(|(batch, _)| batch.revision.get() > revision)
            .map(|(batch, _)| batch.clone())
            .collect())
    }
}
