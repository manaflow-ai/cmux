//! A chat's adoption checkpoint: where the next adoption of its host reads its log from.
//!
//! Leo, 2026-11-19: "we need to be able to have infinite chats, infinitely long chats".
//!
//! Adopting a host after a daemon restart (`hosts.rs` `adopt_held`) folds the chat's log four
//! times (`journal.rs`): the remote env check, the replay cursor, the subagents it started and
//! the work in flight. Each read every byte of the log, so a 4 GB chat read 16 GB at every
//! restart. The adoption's last fold (`recovery_work`) saves every fold's state (`Folds`) at the
//! last record it may hold in `adoption-checkpoint.json`, and the next adoption of the same host
//! incarnation resumes each fold from there: it reads the records after it, not the log.
//!
//! A checkpoint is the whole fold's state at its record, so resuming it gives what a fold of the
//! whole log gives (`hosts_tests.rs` folds both ways at every record). That holds because:
//! - each fold steps the records in order, and depends on the adopted incarnation (kept here:
//!   another one's adoption reads the log whole) and on the inputs in `FoldInputs` (the chat's
//!   native roots, whether it is a remote Claude chain, this build's sandbox profile and env
//!   policy), which must match;
//! - `open_work` parses a record of the log's last turn only while that turn is open, and the
//!   last turn moves on: a checkpoint never holds a record of an open last turn (it ends before
//!   that turn's start), so each record it holds was read as every later fold reads it;
//! - it holds only records written whole (through the log's last seq while no append ran), and
//!   is saved only when the log read to its end;
//! - the record it ends at is checked against the log by `(seq, at, kind)` (an import or a
//!   journal restore replaced it), and a compaction since (which rewrites records in place)
//!   drops it (`Store::adoption_checkpoint`). A fork's log joins its parent's: read whole.
//!
//! A checkpoint that does not match is not used; the adoption reads the whole log and saves a
//! new one. A change to what any fold reads or keeps bumps `VERSION`.

use super::journal::{EnvFold, HostSeqFold, WorkFold};
use super::*;
use crate::store::LinePos;
use crate::subagents::SubagentTree;

/// The checkpoint's format and the folds' meaning. Another one is not read.
const VERSION: u32 = 1;

/// Every adoption fold's state through one record.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Checkpoint {
    v: u32,
    /// The last record folded, its time and kind.
    pub(super) seq: u64,
    at: u64,
    kind: String,
    /// Where the record after it starts, when the fold read it.
    pub(super) next: Option<LinePos>,
    incarnation: String,
    inputs: FoldInputs,
    pub(super) folds: Folds,
}

/// What the folds read besides the log; a checkpoint is good only under the same.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct FoldInputs {
    /// The chat's native root and its earlier ones (never subagents).
    own: Option<String>,
    roots: Vec<String>,
    /// A remote chain's Claude chat (`remote_sandbox.rs` `remote_claude`).
    pub(super) remote_claude: bool,
    /// This build's sandbox profile (`remote_sandbox::profile_id`) and remote env policy.
    pub(super) sandbox_profile: String,
    env_policy: String,
}

impl FoldInputs {
    /// A subagent tree that knows the chat's roots, as the tap seeds one.
    pub(super) fn tree(&self) -> SubagentTree {
        let mut tree = SubagentTree::default();
        tree.set_own(self.own.as_deref());
        tree.set_roots(self.own.iter().chain(&self.roots).map(String::as_str));
        tree
    }
}

/// The adoption's folds (`journal.rs`), stepped together by `recovery_work`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub(super) struct Folds {
    pub(super) env: EnvFold,
    pub(super) host_seq: HostSeqFold,
    pub(super) subagents: SubagentTree,
    pub(super) work: WorkFold,
}

impl Folds {
    pub(super) fn new(inputs: &FoldInputs) -> Self {
        Self {
            env: EnvFold::default(),
            host_seq: HostSeqFold::default(),
            subagents: inputs.tree(),
            work: WorkFold::new(inputs),
        }
    }
}

impl Checkpoint {
    pub(super) fn new(
        seq: u64,
        next: Option<LinePos>,
        incarnation: &str,
        inputs: FoldInputs,
        folds: Folds,
    ) -> Self {
        Self {
            v: VERSION,
            seq,
            at: 0,
            kind: String::new(),
            next,
            incarnation: incarnation.to_owned(),
            inputs,
            folds,
        }
    }
}

impl Hub {
    /// What `session`'s adoption folds read besides its log, now.
    pub(super) fn fold_inputs(&self, session: &Session) -> FoldInputs {
        let meta = session.meta();
        FoldInputs {
            own: meta.agent_session_id.clone(),
            roots: meta.retired_agent_session_ids.clone(),
            remote_claude: self.remote_claude(session),
            sandbox_profile: super::super::remote_sandbox::profile_id(),
            env_policy: crate::agent::REMOTE_ENV_POLICY_ID.to_owned(),
        }
    }

    /// `session`'s adoption checkpoint for host `incarnation`, when it matches its log and
    /// `inputs`; none for a log read whole.
    pub(super) fn adoption_checkpoint(
        &self,
        session: &Session,
        incarnation: &str,
        inputs: &FoldInputs,
    ) -> Option<Checkpoint> {
        let bytes = self.store.adoption_checkpoint(&session.id)?;
        let point: Checkpoint = serde_json::from_slice(&bytes).ok()?;
        if point.v != VERSION
            || point.seq == 0
            || point.seq > session.seq.load(Ordering::SeqCst)
            || point.incarnation != incarnation
            || point.inputs != *inputs
            || session.meta().fork_seq.is_some()
        {
            return None;
        }
        let record = self.record_at(session, point.seq)?;
        (record.at == point.at && record.kind == point.kind).then_some(point)
    }

    /// Saves `point` for `session`'s next adoption. A failed write leaves the last one, which is
    /// still right.
    pub(super) fn save_adoption_checkpoint(&self, session: &Session, mut point: Checkpoint) {
        if session.meta().fork_seq.is_some() {
            return;
        }
        let Some(record) = self.record_at(session, point.seq) else { return };
        point.at = record.at;
        point.kind = record.kind;
        let Ok(bytes) = serde_json::to_vec(&point) else { return };
        if let Err(error) = self.store.save_adoption_checkpoint(&session.id, &bytes) {
            tracing::debug!(session = %session.id, "adoption checkpoint not saved: {error:#}");
        }
    }
}
