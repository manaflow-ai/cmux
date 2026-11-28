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
//! - the record it ends at is checked in full against the log. The log's change count and
//!   system boot must also match, so a rewrite of an earlier record drops it; that count is
//!   checked around the fold and save. A fork's log joins its parent's: read whole.
//!
//! A checkpoint that does not match is not used; the adoption reads the whole log and saves a
//! new one. A change to what any fold reads or keeps bumps `VERSION`.
//!
//! A new host is a new incarnation, and its first adoption read the whole log again: a 1 GB
//! chat's first restart after its host started spent 5.5 s in "adopt agent hosts" against 41 ms
//! on the next one (cmux#51494). So a checkpoint also keeps the folds of an incarnation that has
//! not started (`unstarted`): an incarnation enters every fold only at its own `host_started`
//! (each fold's `current`), so until then its folds are these. An adoption of a host whose
//! `host_started` comes after the checkpoint resumes from them (`kind_index.rs` keeps every
//! `host_started`, so that is read without the log). A chat with no checkpoint gets one in the
//! background when its host starts (`prime_adoption_checkpoint`), or when a daemon reads its log
//! with no host of it running (`journal.rs` `checkpoint_after_load`, saved under `UNSTARTED`),
//! so no restart reads its whole log.

use super::super::processes::SavedProcesses;
use super::journal::{EnvFold, HostSeqFold, WorkFold};
use super::*;
use crate::store::LinePos;
use crate::subagents::SubagentTree;

/// The checkpoint's format and the folds' meaning. Another one is not read.
const VERSION: u32 = 5;

/// The incarnation of no host: the folds it gives are those of any incarnation not started yet.
pub(super) const UNSTARTED: &str = "\u{0}unstarted";

/// Every adoption fold's state through one record.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Checkpoint {
    v: u32,
    /// The last record folded, its time and kind.
    pub(super) seq: u64,
    at: u64,
    kind: String,
    digest: String,
    /// Existing records changed under this count. It is durable within a system boot.
    stamp: u64,
    boot: u64,
    /// Where the record after it starts, when the fold read it.
    pub(super) next: Option<LinePos>,
    incarnation: String,
    inputs: FoldInputs,
    pub(super) folds: Folds,
    /// The folds through `seq` of an incarnation whose `host_started` comes after it.
    #[serde(default)]
    pub(super) unstarted: Option<Folds>,
    /// The chat's process table (`processes.rs`) through `seq` or an earlier record; one an
    /// incarnation does not change. None in a checkpoint saved before it was kept: the next
    /// adoption reads the table from the log's copies, then keeps it.
    #[serde(default)]
    pub(super) processes: Option<SavedProcesses>,
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
        unstarted: Option<Folds>,
        stamp: u64,
    ) -> Self {
        Self {
            v: VERSION,
            seq,
            at: 0,
            kind: String::new(),
            digest: String::new(),
            stamp,
            boot: acpmux_core::boot::system_boot_id(),
            next,
            incarnation: incarnation.to_owned(),
            inputs,
            folds,
            unstarted,
            processes: None,
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
        let mut point: Checkpoint = serde_json::from_slice(&bytes).ok()?;
        if point.incarnation != incarnation {
            // Another host's: its folds before any start of this one are this one's.
            let unstarted = point.unstarted.clone()?;
            if self.started_through(session, incarnation, point.seq) {
                return None;
            }
            point.folds = unstarted;
            point.incarnation = incarnation.to_owned();
        }
        if point.v != VERSION
            || point.seq == 0
            || point.seq > session.seq.load(Ordering::SeqCst)
            || point.inputs != *inputs
            || point.boot != acpmux_core::boot::system_boot_id()
            || self.store.log_stamp(&session.id).ok() != Some(point.stamp)
            || session.meta().fork_seq.is_some()
        {
            return None;
        }
        let record = self.record_at(session, point.seq)?;
        let digest = crate::sha256::sha256_hex(&serde_json::to_vec(&record).ok()?);
        (record.at == point.at && record.kind == point.kind && digest == point.digest)
            .then_some(point)
    }

    /// Whether `session`'s log holds a `host_started` of `incarnation` at `through` or before
    /// (from its kind copy); true when that does not read.
    fn started_through(&self, session: &Session, incarnation: &str, through: u64) -> bool {
        if incarnation == UNSTARTED {
            return false;
        }
        let mut started = false;
        let read = self.store.scan_kinds(&session.id, &["host_started"], &mut |e| {
            started |= e.seq <= through
                && e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation);
            !started
        });
        started || read.is_err()
    }

    /// A host of `session` started: with no checkpoint its adoption could resume from, one is
    /// folded in the background now, at low priority, so the restart that adopts this host reads
    /// only the records after it. It is this incarnation's own (its `host_started` is already in
    /// the log, so unstarted folds would not serve it), with the unstarted folds beside it for
    /// the hosts after. Once a chat has one, each adoption saves the next.
    pub(in crate::hub) fn prime_adoption_checkpoint(
        self: &Arc<Self>,
        session: &Arc<Session>,
        incarnation: &str,
    ) {
        static PRIMING: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());
        if session.meta().fork_seq.is_some() || tokio::runtime::Handle::try_current().is_err() {
            return;
        }
        let (hub, session, incarnation) = (self.clone(), session.clone(), incarnation.to_owned());
        // bare blocking (daemon): a background fold of one chat's log, once per chat at a time
        tokio::task::spawn_blocking(move || {
            {
                let mut priming = PRIMING.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                if priming.contains(&session.id) {
                    return;
                }
                priming.push(session.id.clone());
            }
            crate::qos::background(|| {
                let inputs = hub.fold_inputs(&session);
                if !hub.shutting_down()
                    && hub.adoption_checkpoint(&session, &incarnation, &inputs).is_none()
                {
                    hub.catch_up(&session);
                    let settled = hub.settled_seq(&session);
                    if let Some(point) = hub.fold_checkpoint(&session, &incarnation, settled) {
                        let _ = hub.save_adoption_checkpoint(&session, point);
                    }
                }
            });
            PRIMING
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .retain(|id| *id != session.id);
        });
    }

    /// Saves `point` for `session`'s next adoption. A failed write leaves the last one, which is
    /// still right. Gives back the process table it kept, saved or not, so the caller moves it
    /// on rather than keeping a copy beside it.
    pub(super) fn save_adoption_checkpoint(
        &self,
        session: &Session,
        mut point: Checkpoint,
    ) -> Option<SavedProcesses> {
        let save = |point: &mut Checkpoint| {
            if session.meta().fork_seq.is_some()
                || self.store.log_stamp(&session.id).ok() != Some(point.stamp)
            {
                return;
            }
            let Some(record) = self.record_at(session, point.seq) else { return };
            let Ok(record_bytes) = serde_json::to_vec(&record) else { return };
            point.digest = crate::sha256::sha256_hex(&record_bytes);
            point.at = record.at;
            point.kind = record.kind;
            if self.store.log_stamp(&session.id).ok() != Some(point.stamp) {
                return;
            }
            let Ok(bytes) = serde_json::to_vec(&*point) else { return };
            if let Err(error) = self.store.save_adoption_checkpoint(&session.id, &bytes) {
                tracing::debug!(session = %session.id, "adoption checkpoint not saved: {error:#}");
            }
        };
        save(&mut point);
        point.processes
    }
}
